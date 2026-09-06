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
#define FW_VERSION "1.1"
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
//   byte  8    : battery %
//   byte  9    : number of samples N in this packet
//   then N * 12 bytes: int16 LE  ax, ay, az, gx, gy, gz  (raw sensor counts)
// The 10-byte header lets the app reconstruct exact per-sample times from the
// chip clock and detect dropped samples (a jump in the index). The app applies
// the LSM6DS3 sensitivities (accel +/-16g, gyro 2000 dps).
// =====================================================
#define PKT_HEADER    10
#define MAX_SAMPLES   19              // 10 + 19*12 = 238 bytes, fits a 247-byte MTU
#define SAMPLE_BYTES  12
static uint8_t  txbuf[PKT_HEADER + MAX_SAMPLES * SAMPLE_BYTES];
static uint16_t sampleCount = 0;
static uint32_t lastFlushMs = 0;
static uint32_t sampleIndexTotal = 0;  // cumulative samples since connect
static uint32_t packetFirstIndex = 0;  // index of this packet's first sample
static uint32_t packetFirstMicros = 0; // micros() of this packet's first sample

volatile bool connected = false;
int      batteryPct  = 100;
uint32_t lastBattUs  = 0;

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

  // ---- BLE ----
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);   // must precede begin()
  Bluefruit.begin();
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
    digitalWrite(VBAT_ENABLE, LOW);   // enable divider (active low)
    delay(2);
    int rawADC = analogRead(PIN_VBAT);
    digitalWrite(VBAT_ENABLE, HIGH);
    float vbat = (rawADC / 4096.0f) * 3.6f * (1510.0f / 510.0f);
    int pct = (int)(((vbat - 3.2f) / (4.2f - 3.2f)) * 100.0f);
    batteryPct = constrain(pct, 0, 100);
    lastBattUs = nowUs;
  }

  if (!connected) {
    delay(1);
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
