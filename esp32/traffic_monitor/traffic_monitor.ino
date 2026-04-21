/*
  Router Traffic Monitor
  ESP32 + SSD1306 0.96" 128x64 OLED (I2C)

  Features:
  - Polls router CGI every ~1.6s
  - Auto-detects all connected devices
  - Web UI on port 80 for settings (endpoint, device names, priorities)
  - Settings saved to NVS (survives reboot)
  - Priority sorting: lower number = shown first on OLED
  - Unprioritized devices sorted by highest traffic

  Libraries required:
    Adafruit SSD1306, Adafruit GFX, ArduinoJson, WebServer (built-in)

  Wiring:
    OLED SDA → GPIO 21
    OLED SCL → GPIO 22
*/

#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <WebServer.h>
#include <Preferences.h>

// ── WiFi Credentials ──────────────────────────────────────────
// These are defaults — can be changed via Web UI after first boot
const char* DEFAULT_SSID     = "YourWiFiName";
const char* DEFAULT_PASSWORD = "YourWiFiPassword";
const char* DEFAULT_ENDPOINT = "http://192.168.1.1/cgi-bin/traffic.cgi";
// ─────────────────────────────────────────────────────────────

#define SCREEN_WIDTH   128
#define SCREEN_HEIGHT   64
#define OLED_RESET      -1
#define OLED_ADDRESS   0x3C
#define MAX_DEVICES     20
#define HTTP_TIMEOUT  5000
#define MAX_GAUGE_BPS 104857600.0f  // 100 MB/s

// Layout
#define HEADER_Y    0
#define SEP1_Y      8
#define BODY_TOP    9
#define BODY_H     44
#define SEP2_Y     53
#define FOOTER_Y   55
#define GAUGE_X    52
#define GAUGE_Y    55
#define GAUGE_H     6
#define GAUGE_W    76

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
WebServer        server(80);
Preferences      prefs;

// ── Device struct ─────────────────────────────────────────────
struct Device {
  char  ip[16];
  float rxRate;
  float txRate;
  char  name[16];   // friendly name (editable via web UI)
  int   priority;   // 0 = unprioritized, 1,2,3... = show first
};

Device        devices[MAX_DEVICES];
int           deviceCount = 0;
bool          cursorState = false;
unsigned long bootMs      = 0;

// ── Settings (saved to NVS) ───────────────────────────────────
char  cfg_ssid[64];
char  cfg_password[64];
char  cfg_endpoint[128];

// Per-device settings stored as "name_192.168.1.105" etc
String getDeviceName(const char* ip) {
  prefs.begin("devices", true);
  String key = "n_" + String(ip);
  key.replace('.', '_');
  String val = prefs.getString(key.c_str(), "");
  prefs.end();
  if (val.length() > 0) return val;
  // Default: last octet
  const char* last = strrchr(ip, '.');
  return last ? String(last + 1) : String(ip);
}

int getDevicePriority(const char* ip) {
  prefs.begin("devices", true);
  String key = "p_" + String(ip);
  key.replace('.', '_');
  int val = prefs.getInt(key.c_str(), 0);
  prefs.end();
  return val;
}

void saveDeviceName(const char* ip, const char* name) {
  prefs.begin("devices", false);
  String key = "n_" + String(ip);
  key.replace('.', '_');
  prefs.putString(key.c_str(), name);
  prefs.end();
}

void saveDevicePriority(const char* ip, int priority) {
  prefs.begin("devices", false);
  String key = "p_" + String(ip);
  key.replace('.', '_');
  prefs.putInt(key.c_str(), priority);
  prefs.end();
}

void loadSettings() {
  prefs.begin("config", true);
  String ssid     = prefs.getString("ssid",     DEFAULT_SSID);
  String password = prefs.getString("password", DEFAULT_PASSWORD);
  String endpoint = prefs.getString("endpoint", DEFAULT_ENDPOINT);
  prefs.end();
  ssid.toCharArray(cfg_ssid,         sizeof(cfg_ssid));
  password.toCharArray(cfg_password, sizeof(cfg_password));
  endpoint.toCharArray(cfg_endpoint, sizeof(cfg_endpoint));
}

void saveSettings(const char* ssid, const char* password, const char* endpoint) {
  prefs.begin("config", false);
  prefs.putString("ssid",     ssid);
  prefs.putString("password", password);
  prefs.putString("endpoint", endpoint);
  prefs.end();
  strncpy(cfg_ssid,     ssid,     sizeof(cfg_ssid)     - 1);
  strncpy(cfg_password, password, sizeof(cfg_password) - 1);
  strncpy(cfg_endpoint, endpoint, sizeof(cfg_endpoint) - 1);
}

// ── Helpers ───────────────────────────────────────────────────
String formatRate(float bps) {
  char buf[8];
  if (bps >= 1048576.0f)   snprintf(buf, sizeof(buf), "%4.1fM", bps / 1048576.0f);
  else if (bps >= 1024.0f) snprintf(buf, sizeof(buf), "%4.1fK", bps / 1024.0f);
  else                      snprintf(buf, sizeof(buf), "%4dB",  (int)bps);
  return String(buf);
}

void displayMessage(const char* l1, const char* l2 = "") {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 20); display.println(l1);
  if (strlen(l2)) { display.setCursor(0, 36); display.println(l2); }
  display.display();
}

void dashedHLine(int x1, int x2, int y) {
  for (int x = x1; x <= x2; x += 3)
    display.drawPixel(x, y, SSD1306_WHITE);
}

// ── Renderer ─────────────────────────────────────────────────
void renderDisplay() {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);

  // Header
  display.setCursor(0, HEADER_Y + 1);
  display.print("> NET-MON");

  char badge[8];
  snprintf(badge, sizeof(badge), "[%d]", deviceCount);
  display.setCursor(66, HEADER_Y + 1);
  display.print(badge);

  if (cursorState) display.fillRect(121, HEADER_Y + 1, 5, 6, SSD1306_WHITE);
  else             display.drawRect(121, HEADER_Y + 1, 5, 6, SSD1306_WHITE);

  display.drawLine(0, SEP1_Y, 127, SEP1_Y, SSD1306_WHITE);

  // Sort devices:
  // 1. Priority > 0, sorted ascending (1 first, 2 second...)
  // 2. Priority == 0, sorted by total traffic descending
  int order[MAX_DEVICES];
  int orderCount = 0;

  // First pass: prioritized devices (priority 1,2,3...)
  // Find max priority
  int maxPrio = 0;
  for (int i = 0; i < deviceCount; i++)
    if (devices[i].priority > maxPrio) maxPrio = devices[i].priority;

  for (int p = 1; p <= maxPrio; p++) {
    for (int i = 0; i < deviceCount; i++) {
      if (devices[i].priority == p) {
        order[orderCount++] = i;
        break;
      }
    }
  }

  // Second pass: unprioritized, sorted by traffic descending
  // Simple insertion sort by rxRate+txRate
  int unprio[MAX_DEVICES];
  int unprioCount = 0;
  for (int i = 0; i < deviceCount; i++) {
    if (devices[i].priority == 0) {
      unprio[unprioCount++] = i;
    }
  }
  // Bubble sort descending by total traffic
  for (int a = 0; a < unprioCount - 1; a++) {
    for (int b = a + 1; b < unprioCount; b++) {
      float ta = devices[unprio[a]].rxRate + devices[unprio[a]].txRate;
      float tb = devices[unprio[b]].rxRate + devices[unprio[b]].txRate;
      if (tb > ta) { int tmp = unprio[a]; unprio[a] = unprio[b]; unprio[b] = tmp; }
    }
  }
  for (int i = 0; i < unprioCount; i++)
    order[orderCount++] = unprio[i];

  int N = min(orderCount, 3);

  if (N == 0) {
    display.setCursor(10, BODY_TOP + 18);
    display.print("all devices idle");
  } else {
    int rowH = BODY_H / N;
    for (int r = 0; r < N; r++) {
      int i       = order[r];
      int slotTop = BODY_TOP + r * rowH;
      int textY   = slotTop + (rowH - 7) / 2;

      // Name (max 3 chars to fit layout)
      char shortName[4];
      strncpy(shortName, devices[i].name, 3);
      shortName[3] = '\0';
      display.setCursor(0, textY);
      display.print(shortName);

      // RX
      display.setCursor(20, textY);
      display.print("\x19");
      display.print(formatRate(devices[i].rxRate));

      // TX
      display.setCursor(64, textY);
      display.print("\x18");
      display.print(formatRate(devices[i].txRate));

      if (r < N - 1)
        dashedHLine(0, 127, slotTop + rowH - 1);
    }
  }

  display.drawLine(0, SEP2_Y, 127, SEP2_Y, SSD1306_WHITE);

  // Footer — uptime + gauge
  unsigned long sec = (millis() - bootMs) / 1000;
  char uptime[9];
  snprintf(uptime, sizeof(uptime), "%02lu:%02lu:%02lu",
           sec / 3600, (sec % 3600) / 60, sec % 60);
  display.setCursor(0, FOOTER_Y);
  display.print(uptime);

  float totalBps = 0;
  for (int i = 0; i < deviceCount; i++)
    totalBps += devices[i].rxRate + devices[i].txRate;
  float pct   = constrain(totalBps / MAX_GAUGE_BPS, 0.0f, 1.0f);
  int fillPx  = (int)((GAUGE_W - 2) * pct);

  display.drawRect(GAUGE_X, GAUGE_Y, GAUGE_W, GAUGE_H, SSD1306_WHITE);
  if (fillPx > 0)
    display.fillRect(GAUGE_X + 1, GAUGE_Y + 1, fillPx, GAUGE_H - 2, SSD1306_WHITE);

  display.display();
}

// ── Web UI ────────────────────────────────────────────────────
String buildPage() {
  String html = R"rawhtml(
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Traffic Monitor</title>
<style>
  body{font-family:monospace;background:#111;color:#ddd;margin:0;padding:16px}
  h2{color:#4af;margin-bottom:4px}
  h3{color:#aaa;margin:20px 0 6px}
  input[type=text],input[type=password],input[type=number]{
    background:#222;border:1px solid #444;color:#eee;
    padding:6px 10px;width:100%;box-sizing:border-box;border-radius:4px;
    font-family:monospace;font-size:14px;margin-bottom:8px}
  button{background:#1a6;color:#fff;border:none;padding:8px 20px;
    border-radius:4px;cursor:pointer;font-size:14px}
  button:hover{background:#2b7}
  .card{background:#1a1a1a;border:1px solid #333;border-radius:6px;
    padding:12px 16px;margin-bottom:10px}
  .row{display:flex;gap:8px;align-items:center}
  .row label{width:80px;color:#888;font-size:13px}
  .badge{background:#333;color:#4af;padding:2px 8px;border-radius:3px;
    font-size:12px;float:right}
  .sep{border:none;border-top:1px solid #333;margin:16px 0}
  .hint{color:#666;font-size:12px;margin-top:-4px;margin-bottom:8px}
</style>
</head>
<body>
<h2>&#9632; Traffic Monitor</h2>
<span class="badge">NET-MON</span>

<h3>Router Settings</h3>
<form action="/save-config" method="POST">
  <div class="card">
    <label>WiFi SSID</label>
    <input type="text" name="ssid" value=")rawhtml";
  html += String(cfg_ssid);
  html += R"rawhtml(" placeholder="WiFi network name">
    <label>Password</label>
    <input type="password" name="password" value=")rawhtml";
  html += String(cfg_password);
  html += R"rawhtml(" placeholder="WiFi password">
    <label>Endpoint</label>
    <input type="text" name="endpoint" value=")rawhtml";
  html += String(cfg_endpoint);
  html += R"rawhtml(" placeholder="http://192.168.1.1/cgi-bin/traffic.cgi">
    <p class="hint">Router LAN IP + CGI path</p>
    <button type="submit">Save &amp; Reboot</button>
  </div>
</form>

<hr class="sep">
<h3>Device Names &amp; Priority</h3>
<p class="hint">Priority: 1 = always first, 2 = second, 0 = auto (sorted by traffic)</p>
)rawhtml";

  // Device list from last poll
  if (deviceCount == 0) {
    html += "<p style='color:#666'>No devices detected yet. Wait for a poll cycle.</p>";
  } else {
    html += "<form action='/save-devices' method='POST'>";
    for (int i = 0; i < deviceCount; i++) {
      html += "<div class='card'>";
      html += "<div style='color:#4af;margin-bottom:8px'>";
      html += String(devices[i].ip);
      html += " <span style='color:#666;font-size:12px'>&#8595;";
      html += formatRate(devices[i].rxRate);
      html += " &#8593;";
      html += formatRate(devices[i].txRate);
      html += "</span></div>";
      html += "<div class='row'>";
      html += "<label>Name</label>";
      html += "<input type='text' name='name_";
      html += String(devices[i].ip);
      html += "' value='";
      html += String(devices[i].name);
      html += "' maxlength='15'>";
      html += "</div>";
      html += "<div class='row'>";
      html += "<label>Priority</label>";
      html += "<input type='number' name='prio_";
      html += String(devices[i].ip);
      html += "' value='";
      html += String(devices[i].priority);
      html += "' min='0' max='99' style='width:80px'>";
      html += "</div>";
      html += "</div>";
    }
    html += "<button type='submit'>Save Device Settings</button>";
    html += "</form>";
  }

  html += R"rawhtml(
<hr class="sep">
<h3>Status</h3>
<div class="card">
)rawhtml";
  html += "<div>ESP32 IP: <b>" + WiFi.localIP().toString() + "</b></div>";
  html += "<div>Uptime: <b>";
  unsigned long sec = (millis() - bootMs) / 1000;
  char upbuf[16];
  snprintf(upbuf, sizeof(upbuf), "%02lu:%02lu:%02lu",
           sec/3600, (sec%3600)/60, sec%60);
  html += String(upbuf);
  html += "</b></div>";
  html += "<div>Devices tracked: <b>" + String(deviceCount) + "</b></div>";
  html += "<div>Endpoint: <b>" + String(cfg_endpoint) + "</b></div>";
  html += "</div>";
  html += "</body></html>";
  return html;
}

void handleRoot() {
  server.send(200, "text/html", buildPage());
}

void handleSaveConfig() {
  String ssid     = server.arg("ssid");
  String password = server.arg("password");
  String endpoint = server.arg("endpoint");

  saveSettings(ssid.c_str(), password.c_str(), endpoint.c_str());

  server.send(200, "text/html",
    "<html><body style='background:#111;color:#ddd;font-family:monospace;padding:20px'>"
    "<h3 style='color:#4af'>Settings saved. Rebooting...</h3>"
    "<script>setTimeout(()=>location.href='/',4000)</script>"
    "</body></html>");
  delay(1000);
  ESP.restart();
}

void handleSaveDevices() {
  for (int i = 0; i < deviceCount; i++) {
    String nameKey = "name_" + String(devices[i].ip);
    String prioKey = "prio_" + String(devices[i].ip);
    if (server.hasArg(nameKey)) {
      String name = server.arg(nameKey);
      saveDeviceName(devices[i].ip, name.c_str());
      name.toCharArray(devices[i].name, sizeof(devices[i].name));
    }
    if (server.hasArg(prioKey)) {
      int prio = server.arg(prioKey).toInt();
      saveDevicePriority(devices[i].ip, prio);
      devices[i].priority = prio;
    }
  }
  server.sendHeader("Location", "/");
  server.send(303);
}

void setupWebServer() {
  server.on("/",             HTTP_GET,  handleRoot);
  server.on("/save-config",  HTTP_POST, handleSaveConfig);
  server.on("/save-devices", HTTP_POST, handleSaveDevices);
  server.begin();
}

// ── Parse & Display ───────────────────────────────────────────
void parseAndDisplay(const String& json) {
  StaticJsonDocument<4096> doc;
  DeserializationError err = deserializeJson(doc, json);
  if (err) { displayMessage("JSON error:", err.c_str()); return; }

  JsonArray arr  = doc.as<JsonArray>();
  int newCount   = 0;

  for (JsonObject obj : arr) {
    if (newCount >= MAX_DEVICES) break;
    float rx = obj["rxRate"] | 0.0f;
    float tx = obj["txRate"] | 0.0f;
    if (rx == 0.0f && tx == 0.0f) continue;

    const char* ip = obj["ip"] | "?.?.?.?";
    strncpy(devices[newCount].ip, ip, 15);
    devices[newCount].ip[15] = '\0';
    devices[newCount].rxRate  = rx;
    devices[newCount].txRate  = tx;

    // Load name and priority from NVS
    String name = getDeviceName(ip);
    name.toCharArray(devices[newCount].name, sizeof(devices[newCount].name));
    devices[newCount].priority = getDevicePriority(ip);

    Serial.printf("  %-15s  %-15s  ↓ %8.0f B/s  ↑ %8.0f B/s  prio:%d\n",
                  ip, devices[newCount].name, rx, tx, devices[newCount].priority);
    newCount++;
  }

  deviceCount = newCount;
  cursorState = !cursorState;
  renderDisplay();
}

// ── Poll ─────────────────────────────────────────────────────
void pollRouter() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi lost — reconnecting...");
    displayMessage("WiFi lost...", "Reconnecting");
    WiFi.reconnect();
    for (int i = 0; i < 20 && WiFi.status() != WL_CONNECTED; i++) delay(500);
    if (WiFi.status() != WL_CONNECTED) { delay(2000); return; }
  }

  HTTPClient http;
  http.begin(cfg_endpoint);
  http.setTimeout(HTTP_TIMEOUT);

  Serial.print("Polling... ");
  unsigned long t0   = millis();
  int           code = http.GET();
  unsigned long dt   = millis() - t0;

  if (code == HTTP_CODE_OK) {
    Serial.printf("OK (%lu ms)\n", dt);
    parseAndDisplay(http.getString());
  } else {
    Serial.printf("HTTP %d (%lu ms)\n", code, dt);
    displayMessage("Router error", ("HTTP " + String(code)).c_str());
    delay(2000);
  }

  http.end();
}

// ── Setup ─────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  memset(devices, 0, sizeof(devices));
  bootMs = millis();

  loadSettings();

  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDRESS)) {
    Serial.println("SSD1306 init failed — check wiring or try 0x3D");
    while (true) delay(1000);
  }

  displayMessage("Connecting...", cfg_ssid);
  WiFi.begin(cfg_ssid, cfg_password);

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 40) {
    delay(500);
    Serial.print(".");
    attempts++;
  }
  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    displayMessage("WiFi FAILED", "Check creds");
    // Still start web server for reconfiguration via AP mode
    WiFi.softAP("TrafficMonitor-Setup", "12345678");
    displayMessage("Setup Mode", WiFi.softAPIP().toString().c_str());
    setupWebServer();
    while (true) { server.handleClient(); delay(10); }
  }

  String ip = WiFi.localIP().toString();
  Serial.println("Connected: " + ip);
  Serial.println("Web UI: http://" + ip);
  displayMessage("Connected!", ip.c_str());
  delay(1200);

  setupWebServer();
}

// ── Loop ─────────────────────────────────────────────────────
void loop() {
  server.handleClient();
  pollRouter();
}
