#include <Arduino.h>
#include <ArduinoBLE.h>
#include "LSM6DS3.h"
#include "Wire.h"

// Battery pins for the Seeed XIAO nRF52840 Sense on the mbed core:
// the divider enable P0.14 (active LOW) is Arduino pin 31 here, NOT 14.
// Pin 14 on this core is PIN_LSM6DS3TR_C_POWER — the IMU's power rail —
// so toggling it resets the IMU into power-down mode and every read
// returns 0. (The value 14 is only correct on Seeed's Adafruit-based
// core, which defines VBAT_ENABLE itself and skips this fallback.)
#ifndef PIN_VBAT
  #define PIN_VBAT 32
#endif
#ifndef VBAT_ENABLE
  #define VBAT_ENABLE 31
#endif

// =====================================================
// BLE NORDIC UART UUIDS
// =====================================================
BLEService uartService("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
BLECharacteristic txCharacteristic("6E400003-B5A3-F393-E0A9-E50E24DCCA9E", BLENotify, 255);
BLECharacteristic rxCharacteristic("6E400002-B5A3-F393-E0A9-E50E24DCCA9E", BLEWrite, 255);

LSM6DS3 myIMU(I2C_MODE, 0x6A);

unsigned long lastSampleTime = 0;
unsigned long lastBatteryReadTime = 0;
bool centralConnected = false;
int currentBatteryPct = 100;

// 15-byte binary payload
struct __attribute__((packed)) SensorPacket {
  int16_t ax, ay, az;
  int16_t gx, gy, gz;
  uint16_t dt;
  uint8_t batt;
};

void setup() {
  Serial.begin(115200);
  
  // Wait up to 3 seconds for a USB connection, then run untethered!
  unsigned long startWait = millis();
  while (!Serial && (millis() - startWait < 3000));

  // The IMU sits on the internal Wire1 bus; the LSM6DS3 library powers
  // the sensor and starts that bus itself inside begin().
  if (myIMU.begin() != 0) {
    while (1);
  }

  // Battery setup
  pinMode(PIN_VBAT, INPUT);
  pinMode(VBAT_ENABLE, OUTPUT);
  analogReadResolution(12);
  digitalWrite(VBAT_ENABLE, HIGH); 

  if (!BLE.begin()) {
    while (1);
  }

  BLE.setLocalName("PaddleTrack");
  BLE.setAdvertisedService(uartService);
  uartService.addCharacteristic(txCharacteristic);
  uartService.addCharacteristic(rxCharacteristic);
  BLE.addService(uartService);
  
  BLE.advertise();
  lastSampleTime = micros();
}

void loop() {
  BLEDevice central = BLE.central();

  if (central) {
    if (!centralConnected && central.connected()) {
      centralConnected = true;
      Serial.println("Connected to central: " + central.address());
    }
  } else if (centralConnected) {
    centralConnected = false;
    Serial.println("Disconnected from central");
    BLE.advertise();
  }

  unsigned long currentTime = micros();

  // Read Battery every 2 seconds
  if (currentTime - lastBatteryReadTime > 2000000) {
    digitalWrite(VBAT_ENABLE, LOW); 
    delay(2); 
    int rawADC = analogRead(PIN_VBAT);
    digitalWrite(VBAT_ENABLE, HIGH); 
    
    float vbat = (rawADC / 4096.0) * 3.3 * (1510.0 / 510.0);
    currentBatteryPct = (int)(((vbat - 3.2) / (4.2 - 3.2)) * 100.0);
    
    if (currentBatteryPct > 100) currentBatteryPct = 100;
    if (currentBatteryPct < 0) currentBatteryPct = 0;
    
    lastBatteryReadTime = currentTime;
    currentTime = micros(); 
  }

  unsigned long deltaTimeUs = currentTime - lastSampleTime;
  lastSampleTime = currentTime;

  float ax = myIMU.readFloatAccelX();
  float ay = myIMU.readFloatAccelY();
  float az = myIMU.readFloatAccelZ();
  float gx = myIMU.readFloatGyroX();
  float gy = myIMU.readFloatGyroY();
  float gz = myIMU.readFloatGyroZ();

  // 3. Pack the data into the binary struct
  SensorPacket packet;
  
  // Multiply floats to preserve decimal precision before converting to 16-bit ints
  // Accelerometer: +/- 4G (multiply by 1000 to keep 3 decimal places)
  packet.ax = (int16_t)(ax * 1000);
  packet.ay = (int16_t)(ay * 1000);
  packet.az = (int16_t)(az * 1000);
  
  // Gyroscope: +/- 2000 dps (multiply by 10 to keep 1 decimal place)
  packet.gx = (int16_t)(gx * 10);
  packet.gy = (int16_t)(gy * 10);
  packet.gz = (int16_t)(gz * 10);
  
  packet.dt = (uint16_t)(deltaTimeUs / 1000);
  packet.batt = (uint8_t)currentBatteryPct;

  // 4. Stream the raw bytes over BLE
  if (centralConnected && txCharacteristic.subscribed()) {
    txCharacteristic.writeValue((uint8_t*)&packet, sizeof(packet));
  }

  delay(10);
}