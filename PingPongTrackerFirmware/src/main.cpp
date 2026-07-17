#include <Arduino.h>
#include <ArduinoBLE.h>
#include "LSM6DS3.h"
#include "Wire.h"

#ifndef PIN_VBAT
  #define PIN_VBAT 32
#endif
#ifndef VBAT_ENABLE
  #define VBAT_ENABLE 14
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

void setup() {
  Serial.begin(115200);
  
  // Wait up to 3 seconds for a USB connection, then run untethered!
  unsigned long startWait = millis();
  while (!Serial && (millis() - startWait < 3000));

  // HARDWARE FIX: Wake up the I2C bus before initializing the IMU
  Wire.begin();
  delay(100); 

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

  String blePacket = String(ax, 3) + "," + 
                     String(ay, 3) + "," + 
                     String(az, 3) + "," + 
                     String(gx, 2) + "," + 
                     String(gy, 2) + "," + 
                     String(gz, 2) + "," + 
                     String(deltaTimeUs / 1000.0, 2) + "," + 
                     String(currentBatteryPct) + "\n";

  if (centralConnected && txCharacteristic.subscribed()) {
    txCharacteristic.writeValue((const uint8_t*)blePacket.c_str(), blePacket.length());
  }

  delay(10);
}