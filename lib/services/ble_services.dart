import 'dart:convert';
import 'dart:developer'; // Importamos log()
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleNavigationService {
  // Bandera para saber si "estamos conectados"
  bool isConnected = false;

  // 1. Simular la conexión (sin flutter_blue_plus)
  Future<void> connectToDashboard() async {
    log("Buscando ESP32-S3...", name: "BLE_MOCK");
    
    // Simulamos el tiempo que tarda en conectar
    await Future.delayed(const Duration(seconds: 3)); 
    
    isConnected = true;
    log("¡Conectado virtualmente al ESP32-S3!", name: "BLE_MOCK");
  }

  // 2. Simular el envío de la actualización
  Future<void> sendNavigationUpdate(int maniobra, int distanciaManiobra, int distanciaDestino, int velocidadActual, int limiteVelocidad, int progresoViaje) async {
    if (!isConnected) {
      log("Aviso: Intentando enviar datos sin estar conectado.", name: "BLE_MOCK", level: 900);
      return;
    }

    // Armamos el mapa
    final data = {
        "tipoManiobra": maniobra,
        "distanciaManiobra": distanciaManiobra,
        "distanciaDestino": distanciaDestino,
        "velocidadActual": velocidadActual,
        "limiteVelocidad": limiteVelocidad,
        "progresoViaje": progresoViaje
    };
    
    String jsonString = jsonEncode(data);
    List<int> bytes = utf8.encode(jsonString);

    // En lugar de enviar por txCharacteristic, lo imprimimos en consola
    print("BLE_MOCK 📡 Enviando ${bytes.length} bytes -> $jsonString");
  }
}