#include <Arduino.h>
#include <bluefruit.h>   // Adafruit Bluefruit (SoftDevice S140) BLE stack
#include "LSM6DS3.h"
#include "Wire.h"

// =====================================================
// IMU  (LSM6DS3TR-C, internal I2C bus = Wire1 on the XIAO Sense)
// The Seeed library remaps Wire->Wire1 when TARGET_SEEED_XIAO_NRF52840_SENSE
// is defined; we set that macro in platformio.ini for the Adafruit core.
// =====================================================
LSM6DS3 myIMU(I2C_MODE, 0x6A);

#define LSM6DS3_STATUS_REG 0x1E   // bit0 XLDA (accel new), bit1 GDA (gyro new)
#define LSM6DS3_OUTX_L_G   0x22   // gx,gy,gz,ax,ay,az are contiguous 0x22..0x2D

// =====================================================
// BLE - Nordic UART UUIDs (little-endian 128-bit, same as the app expects)
//   service 6E400001-..., TX (notify) 6E400003-...
// =====================================================
const uint8_t UART_SERVICE_UUID[16] = {
  0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
  0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E};
const uint8_t UART_TX_UUID[16] = {
  0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
  0x93, 0xF3, 0xA3, 0xB5, 0x03, 0x00, 0x40, 0x6E};
// Firmware version string, exposed as a READ characteristic (UUID ...0004...)
// so the app can show it on connect. Bump on firmware changes (1.0, 1.1, ...).
#define FW_VERSION "1.4"
const uint8_t UART_VER_UUID[16] = {
  0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
  0x93, 0xF3, 0xA3, 0xB5, 0x04, 0x00, 0x40, 0x6E};

BLEService        uartService(UART_SERVICE_UUID);
BLECharacteristic txChar(UART_TX_UUID);
BLECharacteristic verChar(UART_VER_UUID);

// =====================================================
// Batched notification buffer (firmware v1.1 packet)
//   bytes 0..3 : uint32 LE  first-sample index (cumulative; resets on connect)
//   bytes 4..7 : uint32 LE  first-sample timestamp = micros() from the chip
//   byte  8    : battery % in bits 0..6; bit 7 = charging flag (fw >= 1.3)
//   byte  9    : number of samples N in this packet
//   bytes 10..11 : uint16 LE  battery millivolts (fw >= 1.3; 0 if unread)
//   then N * 12 bytes: int16 LE  ax, ay, az, gx, gy, gz  (raw sensor counts)
// The 12-byte header lets the app reconstruct exact per-sample times from the
// chip clock and detect dropped samples (a jump in the index). The app applies
// the LSM6DS3 sensitivities (accel +/-16g, gyro 2000 dps).
// Byte 8's coarse % stays for backward compatibility; fw >= 1.3 also sends the
// raw millivolts (bytes 10..11) so the app can map SoC on a real LiPo curve at
// sub-1% resolution. While charging (fw >= 1.3) the board does NOT stream IMU
// data: it sends a header-only status packet (N = 0, battery byte bit 7 set,
// plus the mV) ~2 Hz instead, so the app shows a dedicated charging state.
// =====================================================
#define PKT_HEADER    12
#define MAX_SAMPLES   19              // 12 + 19*12 = 240 bytes, fits a 247-byte MTU
#define SAMPLE_BYTES  12
static uint8_t  txbuf[PKT_HEADER + MAX_SAMPLES * SAMPLE_BYTES];
static uint16_t sampleCount = 0;
static uint32_t lastFlushMs = 0;
static uint32_t sampleIndexTotal = 0;  // cumulative samples since connect
static uint32_t packetFirstIndex = 0;  // index of this packet's first sample
static uint32_t packetFirstMicros = 0; // micros() of this packet's first sample

// Charge-status input from the BQ25101 (the line that drives the on-board CHG
// LED). P0.17 / Arduino pin 23 on the XIAO nRF52840; it reads LOW while the
// battery is charging and HIGH otherwise (open-drain, so we pull it up).
#define PIN_CHARGE_STATE 23

volatile bool connected = false;
int      batteryPct   = 100;
uint16_t batteryMv    = 0;       // raw cell millivolts (fw >= 1.3 packet field)
uint32_t lastBattUs   = 0;
bool     charging     = false;   // refreshed from PIN_CHARGE_STATE each loop
uint32_t lastStatusMs = 0;       // cadence for charging-status packets

// ---- Status LED (onboard user RGB, driven manually; Bluefruit auto-LED off) ----
// Colour encodes power/charge state; blink encodes BLE. On this board the dies
// are active-LOW (pin LOW = lit) — the variant's LED_STATE_ON is wrong, so we
// don't use it. Only one die is ever lit, so colours never blend.
//   green = charging     blue = on & running (charged/full or on battery)
//   red   = low battery  (off only when powered down)
//   blink = BLE searching     solid = BLE connected
#define LED_BLINK_MS   300   // half-period of the searching / charging flash
// Active-low PWM: brightness rises as the value falls (~50% ≈ 128, ~75% ≈ 64).
#define LED_DUTY_BLUE  128   // ~50%
#define LED_DUTY_GREEN 64    // ~75%
#define LED_DUTY_RED   128   // ~50% (tune later)
#define BATT_LOW_MV   3730   // low-battery: matches the app's red threshold (LiPo 20%)
#define BATT_LOW_CLR  3770   // hysteresis: clear "low" only once back above this
bool lowBatt = false;
enum LedColor { LED_C_OFF, LED_C_BLUE, LED_C_GREEN, LED_C_RED };

void connectCallback(uint16_t connHandle) {
  BLEConnection* conn = Bluefruit.Connection(connHandle);
  // Everything that maximizes throughput so a high sample rate can stream:
  conn->requestPHY();                     // 2 Mbps PHY
  conn->requestDataLengthUpdate();        // BLE data length extension
  conn->requestMtuExchange(247);          // large MTU -> big batched packets
  conn->requestConnectionParameter(6);    // 6 * 1.25 ms = 7.5 ms interval
  sampleIndexTotal = 0;                    // restart the sample counter per link
  connected = true;
  Serial.println("Central connected");
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void)connHandle;
  (void)reason;
  connected = false;
  sampleCount = 0;
  Serial.println("Central disconnected");
}

// Read the battery divider (oversampled) into batteryMv + coarse batteryPct.
// Called once in setup() to prime the values, then every 2 s from loop(), so a
// packet never ships an unread mV of 0 (which the app would map to a stuck 0%).
void sampleBattery() {
  digitalWrite(VBAT_ENABLE, LOW);   // enable divider (active low)
  delay(2);
  // Oversample: one analogRead carries the full ADC noise, so average 64 of
  // them (~8x less noise, still well under 1 ms) before scaling to volts.
  uint32_t acc = 0;
  for (int i = 0; i < 64; i++) acc += analogRead(PIN_VBAT);
  digitalWrite(VBAT_ENABLE, HIGH);
  float rawADC = acc / 64.0f;
  float vbat = (rawADC / 4096.0f) * 3.6f * (1510.0f / 510.0f);
  batteryMv = (uint16_t)(vbat * 1000.0f);   // raw mV -> app maps SoC on a LiPo curve
  // Coarse % kept for older apps; the app prefers the mV field when present.
  int pct = (int)(((vbat - 3.2f) / (4.2f - 3.2f)) * 100.0f);
  batteryPct = constrain(pct, 0, 100);
}

// Per-colour lit level (active-low: lower = brighter).
static inline uint8_t ledLit(LedColor c) {
  switch (c) {
    case LED_C_GREEN: return LED_DUTY_GREEN;
    case LED_C_RED:   return LED_DUTY_RED;
    default:          return LED_DUTY_BLUE;
  }
}

// Light exactly one colour (or none) — one die at a time, so nothing blends.
void setStatusLed(LedColor c, bool on) {
  uint8_t v = on ? ledLit(c) : 255;   // 255 = off (held HIGH)
  analogWrite(LED_RED,   c == LED_C_RED   ? v : 255);
  analogWrite(LED_GREEN, c == LED_C_GREEN ? v : 255);
  analogWrite(LED_BLUE,  c == LED_C_BLUE  ? v : 255);
}

// Status-LED state machine, polled every loop. "Charge complete" isn't
// distinguished from "on battery" — both are not-charging, so both show blue
// (on & charged). Only touches the pins when the state actually changes.
void updateStatusLed() {
  if (batteryMv <= BATT_LOW_MV) lowBatt = true;
  else if (batteryMv >= BATT_LOW_CLR) lowBatt = false;

  LedColor color = charging
                       ? LED_C_GREEN                       // actively charging
                       : (lowBatt ? LED_C_RED : LED_C_BLUE);  // charged/full or on battery

  bool on = connected ? true                               // solid when connected
                      : (((millis() / LED_BLINK_MS) & 1) == 0);  // blink when searching

  static LedColor lastColor = LED_C_OFF;
  static bool lastOn = false;
  static bool inited = false;
  if (inited && color == lastColor && on == lastOn) return;
  lastColor = color;
  lastOn = on;
  inited = true;
  setStatusLed(color, on);
}

void setup() {
  Serial.begin(115200);
  uint32_t startWait = millis();
  while (!Serial && (millis() - startWait < 2000)) {}

  // ---- IMU: configure for the maximum ODR both sensors share (1660 Hz) ----
  myIMU.settings.gyroEnabled      = 1;
  myIMU.settings.gyroRange        = 2000;   // deg/s
  myIMU.settings.gyroSampleRate   = 1660;   // Hz (gyro max)
  myIMU.settings.gyroFifoEnabled  = 0;
  myIMU.settings.accelEnabled     = 1;
  myIMU.settings.accelRange       = 16;     // g
  myIMU.settings.accelSampleRate  = 1660;   // Hz
  myIMU.settings.accelFifoEnabled = 0;
  myIMU.settings.tempEnabled      = 0;
  if (myIMU.begin() != 0) {
    Serial.println("IMU init failed");
    while (1) {}
  }
  Wire1.setClock(400000);   // 400 kHz I2C so a 12-byte burst read is ~0.35 ms

  // ---- Battery divider (VBAT_ENABLE / PIN_VBAT provided by the variant) ----
  pinMode(PIN_VBAT, INPUT);
  pinMode(VBAT_ENABLE, OUTPUT);
  analogReadResolution(12);
  digitalWrite(VBAT_ENABLE, HIGH);   // divider off until we sample
  pinMode(PIN_CHARGE_STATE, INPUT_PULLUP);  // open-drain CHG line; LOW = charging
  sampleBattery();                          // prime batteryMv/Pct before streaming

  // ---- BLE ----
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);   // must precede begin()
  Bluefruit.begin();
  Bluefruit.autoConnLed(false);        // we drive the RGB status LED ourselves
  setStatusLed(LED_C_OFF, false);      // dark until the first loop() state update
  Bluefruit.setTxPower(4);
  Bluefruit.setName("PaddleTrack");
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);
  Bluefruit.Periph.setConnInterval(6, 12);        // 7.5 - 15 ms

  uartService.begin();                            // service first...
  txChar.setProperties(CHR_PROPS_NOTIFY);         // ...then its characteristic
  txChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  txChar.setMaxLen(sizeof(txbuf));
  txChar.begin();

  // Firmware version, read once by the app on connect.
  verChar.setProperties(CHR_PROPS_READ);
  verChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  verChar.setMaxLen(8);
  verChar.begin();
  verChar.write(FW_VERSION, sizeof(FW_VERSION) - 1);

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(uartService);
  Bluefruit.ScanResponse.addName();               // name lives in scan response
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);     // units of 0.625 ms
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);                 // advertise forever

  lastFlushMs = millis();
  lastBattUs  = micros();
  Serial.println("PaddleTrack advertising (Bluefruit, 1660 Hz IMU)");
}

void loop() {
  // ---- Battery every 2 s ----
  uint32_t nowUs = micros();
  if (nowUs - lastBattUs > 2000000UL) {
    sampleBattery();
    lastBattUs = nowUs;
  }

  // Charge-status line (LOW = charging). Cheap to poll every loop.
  charging = (digitalRead(PIN_CHARGE_STATE) == LOW);
  updateStatusLed();

  if (!connected) {
    delay(1);
    return;
  }

  // ---- Charging: do NOT stream IMU. Send a small header-only status packet
  // ~2 Hz (N = 0, battery byte bit 7 set) so the app shows a dedicated charging
  // state and a live battery %. Not streaming also frees the ~50 mA charge
  // current to actually fill the cell instead of running the sensor+radio. ----
  if (charging) {
    sampleCount = 0;                        // drop any half-filled stream batch
    uint32_t nowMs = millis();
    if (nowMs - lastStatusMs >= 1000) {     // ~1 Hz status while charging (low rate)
      memset(txbuf, 0, PKT_HEADER);
      txbuf[8] = (uint8_t)(batteryPct | 0x80);  // bit7 = charging
      txbuf[9] = 0;                             // N = 0 (no samples)
      memcpy(&txbuf[10], &batteryMv, 2);        // raw cell mV
      txChar.notify(txbuf, PKT_HEADER);
      lastStatusMs = nowMs;
    }
    delay(5);
    return;
  }

  // ---- Capture a new IMU sample when the sensor flags data-ready ----
  uint8_t status = 0;
  myIMU.readRegister(&status, LSM6DS3_STATUS_REG);
  if ((status & 0x01) && sampleCount < MAX_SAMPLES) {   // XLDA: fresh accel data
    uint8_t raw[12];
    if (myIMU.readRegisterRegion(raw, LSM6DS3_OUTX_L_G, 12) == 0) {
      if (sampleCount == 0) {                 // stamp this packet's first sample
        packetFirstMicros = micros();
        packetFirstIndex  = sampleIndexTotal;
      }
      // burst layout is gyro(0..5) then accel(6..11); repack accel-first
      uint16_t off = PKT_HEADER + sampleCount * SAMPLE_BYTES;
      memcpy(&txbuf[off + 0], &raw[6], 6);   // ax, ay, az
      memcpy(&txbuf[off + 6], &raw[0], 6);   // gx, gy, gz
      sampleCount++;
      sampleIndexTotal++;
    }
  }

  // ---- Flush a batched notification when full or after a short latency cap ----
  BLEConnection* conn = Bluefruit.Connection(0);
  uint16_t mtu = conn ? conn->getMtu() : 23;
  uint16_t cap = (mtu > 5) ? ((mtu - 3 - PKT_HEADER) / SAMPLE_BYTES) : 1;
  if (cap > MAX_SAMPLES) cap = MAX_SAMPLES;
  if (cap < 1) cap = 1;

  uint32_t nowMs = millis();
  bool full    = sampleCount >= cap;
  bool timeout = sampleCount > 0 && (nowMs - lastFlushMs >= 15);
  if (full || timeout) {
    memcpy(&txbuf[0], &packetFirstIndex, 4);   // uint32 LE first-sample index
    memcpy(&txbuf[4], &packetFirstMicros, 4);  // uint32 LE first-sample micros
    txbuf[8] = (uint8_t)batteryPct;
    txbuf[9] = (uint8_t)sampleCount;
    memcpy(&txbuf[10], &batteryMv, 2);         // raw cell mV
    uint16_t len = PKT_HEADER + sampleCount * SAMPLE_BYTES;
    if (txChar.notify(txbuf, len)) {
      sampleCount = 0;
      lastFlushMs = nowMs;
    } else if (sampleCount >= MAX_SAMPLES) {
      // notify queue full and buffer maxed: drop oldest batch to keep sampling
      sampleCount = 0;
      lastFlushMs = nowMs;
    }
  }
}
