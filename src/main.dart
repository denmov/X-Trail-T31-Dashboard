import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

void main() {
  runApp(const XTrailT31DashboardApp());
}

class XTrailT31DashboardApp extends StatelessWidget {
  const XTrailT31DashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'X-Trail T31 CAN Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF12151C),
        cardColor: const Color(0xFF1E232E),
      ),
      home: const DashboardScreen(),
    );
  }
}

// Модель данных состояния автомобиля
class CarTelemetry {
  // Скорости колес (км/ч): FL (Перед лев), FR (Перед прав), RL (Зад лев), RR (Зад прав)
  double speedFL = 0.0;
  double speedFR = 0.0;
  double speedRL = 0.0;
  double speedRR = 0.0;

  // Вариатор
  double cvtTemp = 0.0; // °C

  // Полный привод
  String awdMode = "AUTO"; // 2WD, AUTO, LOCK
  int awdTorqueSplitRear = 0; // От 0 до 50% на заднюю ось
  double awdSolenoidCurrent = 0.0; // Ток муфты в Амперах

  // Вычисляемые статусы пробуксовки (true = буксует)
  Map<String, bool> wheelSlip = {'FL': false, 'FR': false, 'RL': false, 'RR': false};
  Map<String, double> slipRatio = {'FL': 0.0, 'FR': 0.0, 'RL': 0.0, 'RR': 0.0};

  // Виртуальный TPMS: накопленное отклонение радиуса и статус ("OK", "LOW")
  Map<String, String> tpmsStatus = {'FL': 'OK', 'FR': 'OK', 'RL': 'OK', 'RR': 'OK'};
  Map<String, double> tpmsDeviation = {'FL': 0.0, 'FR': 0.0, 'RL': 0.0, 'RR': 0.0};
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isDemoMode = false;
  String _statusLog = "Отключено. Выберите ELM327 или запустите Демо-режим.";

  final CarTelemetry _telemetry = CarTelemetry();
  Timer? _pollingTimer;
  int _pollStep = 0;
  String _rxBuffer = "";

  // Буферы для калибровки и сглаживания косвенного TPMS
  final Map<String, double> _tpmsAccumulator = {'FL': 0.0, 'FR': 0.0, 'RL': 0.0, 'RR': 0.0};
  int _tpmsSamplesCount = 0;

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  // ==================== ПОДКЛЮЧЕНИЕ И ИНИЦИАЛИЗАЦИЯ ELM327 ====================

  Future<void> _connectToElm() async {
    try {
      final List<BluetoothDevice> devices =
          await FlutterBluetoothSerial.instance.getBondedDevices();

      if (!mounted) return;

      // Показываем диалог выбора спаренного Bluetooth-устройства
      final BluetoothDevice? selectedDevice = await showDialog<BluetoothDevice>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Выберите ELM327 (v1.5)'),
          children: devices
              .map((d) => SimpleDialogOption(
                    child: Text("${d.name ?? 'Неизвестно'} (${d.address})"),
                    onPressed: () => Navigator.pop(context, d),
                  ))
              .toList(),
        ),
      );

      if (selectedDevice == null) return;

      setState(() => _statusLog = "Подключение к ${selectedDevice.name}...");
      _connection = await BluetoothConnection.toAddress(selectedDevice.address);

      setState(() {
        _isConnected = true;
        _isDemoMode = false;
        _statusLog = "Подключено! Инициализация CAN-шины T31...";
      });

      _connection!.input!.listen(_onDataReceived).onDone(() {
        setState(() {
          _isConnected = false;
          _statusLog = "Соединение разорвано.";
        });
        _pollingTimer?.cancel();
      });

      await _initElm327();
      _startCanPolling();
    } catch (e) {
      setState(() => _statusLog = "Ошибка подключения: $e");
    }
  }

  Future<void> _sendCommand(String cmd, {int delayMs = 120}) async {
    if (_connection != null && _isConnected) {
      _connection!.output.add(Uint8List.fromList(utf8.encode("$cmd\r")));
      await _connection!.output.allSent;
      await Future.delayed(Duration(milliseconds: delayMs));
    }
  }

  Future<void> _initElm327() async {
    // Настройка ELM327 под протокол Nissan CAN (ISO 15765-4 CAN 11bit 500k)
    await _sendCommand("AT Z", delayMs: 500); // Сброс
    await _sendCommand("AT E0");              // Отключить эхо
    await _sendCommand("AT L0");              // Отключить переводы строк
    await _sendCommand("AT S0");              // Отключить пробелы в ответах (для быстрого парсинга)
    await _sendCommand("AT H0");              // Скрыть заголовки
    await _sendCommand("AT SP 6");            // Протокол 6: CAN 11bit 500kb
    setState(() => _statusLog = "CAN 500kbps активен. Чтение ЭБУ...");
  }

  // ==================== ЦИКЛ ОПРОСА БЛОКОВ NISSAN X-TRAIL T31 ====================

  void _startCanPolling() {
    _pollingTimer?.cancel();
    // Цикл выполняется каждые 200 мс, переключая блоки по кругу
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) async {
      if (!_isConnected) return;

      switch (_pollStep) {
        case 0:
          // Шаг 0 и 1: Опрос блока ABS (740 -> 760) — скорости колес нужны чаще всего
          await _sendCommand("AT SH 740", delayMs: 40);
          await _sendCommand("AT CRA 760", delayMs: 40);
          await _sendCommand("2101", delayMs: 80); // Пакет скоростей колес ABS
          break;
        case 1:
          // Опрос блока 4WD (743 -> 763)
          await _sendCommand("AT SH 743", delayMs: 40);
          await _sendCommand("AT CRA 763", delayMs: 40);
          await _sendCommand("2101", delayMs: 80); // Ток муфты и режим 4WD
          break;
        case 2:
          // Снова опрос ABS для высокой частоты детекции пробуксовки
          await _sendCommand("AT SH 740", delayMs: 40);
          await _sendCommand("AT CRA 760", delayMs: 40);
          await _sendCommand("2101", delayMs: 80);
          break;
        case 3:
          // Опрос вариатора Jatco JF011E (7E1 -> 7E9) — температура меняется медленно
          await _sendCommand("AT SH 7E1", delayMs: 40);
          await _sendCommand("AT CRA 7E9", delayMs: 40);
          await _sendCommand("2101", delayMs: 80);
          break;
      }

      _pollStep = (_pollStep + 1) % 4;
    });
  }

  // ==================== ПАРСИНГ ОТВЕТОВ И МАТЕМАТИКА ====================

  void _onDataReceived(Uint8List data) {
    _rxBuffer += ascii.decode(data, allowInvalid: true);
    if (_rxBuffer.contains(">")) {
      final String rawResponse = _rxBuffer.replaceAll("\r", "").replaceAll("\n", "").replaceAll(">", "").trim();
      _rxBuffer = "";
      _parseCanFrame(rawResponse);
    }
  }

  void _parseCanFrame(String hexStr) {
    if (hexStr.isEmpty || hexStr.contains("NO DATA") || hexStr.contains("ERROR")) return;

    // Убираем номера строк многокадрового ответа ISO-TP (0:, 1:, 2: и т.д.)
    final String cleanHex = hexStr.replaceAll(RegExp(r'[0-9A-F]:'), '');
    final List<int> bytes = _hexToBytes(cleanHex);
    if (bytes.length < 4) return;

    setState(() {
      // В зависимости от текущего шага опроса интерпретируем пакет ответа 61 01 ...
      if (bytes[0] == 0x61 && bytes[1] == 0x01) {
        if (_pollStep == 1 || _pollStep == 3) {
          // Ответ от предыдущего шага ABS (так как ответ приходит с небольшой задержкой)
          _parseAbsData(bytes);
        } else if (_pollStep == 2) {
          _parseAwdData(bytes);
        } else if (_pollStep == 0) {
          _parseCvtData(bytes);
        }
      }
      _calculateSlipAndVirtualTpms();
    });
  }

  // 1. Парсинг скоростей колес из ответа блока ABS (61 01 ...)
  void _parseAbsData(List<int> b) {
    if (b.length >= 10) {
      // На Nissan T31 скорости колес передаются двухбайтовыми значениями (1/100 км/ч или 1/16 км/ч в зависимости от ревизии блока)
      _telemetry.speedFL = ((b[2] << 8) + b[3]) / 100.0;
      _telemetry.speedFR = ((b[4] << 8) + b[5]) / 100.0;
      _telemetry.speedRL = ((b[6] << 8) + b[7]) / 100.0;
      _telemetry.speedRR = ((b[8] << 8) + b[9]) / 100.0;
    }
  }

  // 2. Парсинг блока 4WD All-Mode (61 01 ...)
  void _parseAwdData(List<int> b) {
    if (b.length >= 6) {
      // Ток соленоида муфты (в мА -> переводим в Амперы, макс ~2.8А = 50% блокировки)
      int currentMa = (b[2] << 8) + b[3];
      _telemetry.awdSolenoidCurrent = currentMa / 1000.0;
      _telemetry.awdTorqueSplitRear = ((_telemetry.awdSolenoidCurrent / 2.8) * 50).clamp(0, 50).round();

      // Байт статуса переключателя шайбы 4WD
      int modeByte = b[4];
      if (modeByte == 0x00) {
        _telemetry.awdMode = "2WD";
      } else if (modeByte == 0x02) {
        _telemetry.awdMode = "LOCK";
      } else {
        _telemetry.awdMode = "AUTO";
      }
    }
  }

  // 3. Парсинг температуры вариатора Jatco JF011E (61 01 ...)
  void _parseCvtData(List<int> b) {
    // В пакете 21 01 от TCM JF011E байт температуры (обычно 10-й байт полезной нагрузки)
    // Переводится из сырого значения АЦП или по формуле T = Byte - 50
    if (b.length >= 12) {
      int rawTemp = b[10];
      // Стандартная линейная аппроксимация для рабочего диапазона датчика JF011E:
      _telemetry.cvtTemp = (rawTemp - 50).toDouble();
    }
  }

  // 4. Математика пробуксовки и Виртуального TPMS (через ABS)
  void _calculateSlipAndVirtualTpms() {
    final Map<String, double> speeds = {
      'FL': _telemetry.speedFL,
      'FR': _telemetry.speedFR,
      'RL': _telemetry.speedRL,
      'RR': _telemetry.speedRR,
    };

    // Опорная скорость кузова — минимальная из 4 колес (наиболее зацепленное колесо при разгоне)
    double vRef = speeds.values.reduce(min);
    double vAvg = speeds.values.reduce((a, b) => a + b) / 4.0;

    bool anySlip = false;

    // --- АЛГОРИТМ ДЕТЕКЦИИ ПРОБУКСОВКИ ---
    speeds.forEach((wheel, speed) {
      double diff = speed - vRef;
      // Считаем пробуксовкой превышение скорости колеса над опорной более чем на 2.5 км/ч
      if (vRef > 3.0 && diff > 2.5) {
        _telemetry.wheelSlip[wheel] = true;
        _telemetry.slipRatio[wheel] = ((diff / vRef) * 100).clamp(0.0, 999.0);
        anySlip = true;
      } else if (vRef <= 3.0 && speed > 4.0) {
        // Старт с места с пробуксовкой, когда хотя бы одно колесо еще стоит
        _telemetry.wheelSlip[wheel] = true;
        _telemetry.slipRatio[wheel] = 100.0;
        anySlip = true;
      } else {
        _telemetry.wheelSlip[wheel] = false;
        _telemetry.slipRatio[wheel] = 0.0;
      }
    });

    // --- АЛГОРИТМ ВИРТУАЛЬНОГО TPMS (iTPMS по датчикам ABS) ---
    // Накапливаем статистику только при равномерном прямолинейном движении (40..110 км/ч) и без букса
    double leftRightDiff = ((_telemetry.speedFL + _telemetry.speedRL) - (_telemetry.speedFR + _telemetry.speedRR)).abs();
    bool isGoingStraight = leftRightDiff < 0.8; // Не в повороте

    if (!anySlip && isGoingStraight && vAvg > 40.0 && vAvg < 110.0) {
      _tpmsSamplesCount++;
      speeds.forEach((wheel, speed) {
        // Процентное отклонение скорости колеса от среднего по больнице
        // Если колесо спущено -> его радиус меньше -> оно крутится БЫСТРЕЕ среднего (dev > 0)
        double devPercent = ((speed - vAvg) / vAvg) * 100.0;
        _tpmsAccumulator[wheel] = (_tpmsAccumulator[wheel]! * 0.95) + (devPercent * 0.05);
        _telemetry.tpmsDeviation[wheel] = _tpmsAccumulator[wheel]!;

        // Порог срабатывания: если колесо стабильно вращается на 0.45% быстрее среднего (соответствует падению ~0.5 бар)
        if (_tpmsSamplesCount > 30 && _telemetry.tpmsDeviation[wheel]! > 0.45) {
          _telemetry.tpmsStatus[wheel] = 'LOW';
        } else {
          _telemetry.tpmsStatus[wheel] = 'OK';
        }
      });
    }
  }

  List<int> _hexToBytes(String hex) {
    List<int> bytes = [];
    for (int i = 0; i + 1 < hex.length; i += 2) {
      final part = hex.substring(i, i + 2);
      final val = int.tryParse(part, radix: 16);
      if (val != null) bytes.add(val);
    }
    return bytes;
  }

  // ==================== СИМУЛЯТОР (ДЕМО-РЕЖИМ ДЛЯ ПРОВЕРКИ НА ЭКРАНЕ) ====================

  void _toggleDemoMode() {
    _pollingTimer?.cancel();
    setState(() {
      _isDemoMode = !_isDemoMode;
      _statusLog = _isDemoMode
          ? "Демо-режим активен: симуляция пробуксовки FL и спущенного колеса RR"
          : "Демо-режим остановлен.";
    });

    if (_isDemoMode) {
      int tick = 0;
      _pollingTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
        tick++;
        setState(() {
          // Каждые 15 тиков имитируем пробуксовку переднего левого колеса и подключение заднего моста
          bool simulateSlip = (tick % 20) < 6;

          _telemetry.speedRL = 60.0;
          // Заднее правое крутится чуть быстрее (имитация падения давления на 0.6 бар)
          _telemetry.speedRR = 60.45;
          _telemetry.speedFR = 60.0;
          _telemetry.speedFL = simulateSlip ? 68.5 : 60.0;

          _telemetry.cvtTemp = 78.0 + (tick % 10) * 1.5; // Температура вариатора 78..92 °C
          _telemetry.awdMode = "AUTO";
          _telemetry.awdTorqueSplitRear = simulateSlip ? 45 : 5;
          _telemetry.awdSolenoidCurrent = simulateSlip ? 2.4 : 0.2;

          _calculateSlipAndVirtualTpms();
        });
      });
    }
  }

  void _resetTpmsCalibration() {
    setState(() {
      _tpmsSamplesCount = 0;
      _tpmsAccumulator.updateAll((key, value) => 0.0);
      _telemetry.tpmsStatus.updateAll((key, value) => 'OK');
      _telemetry.tpmsDeviation.updateAll((key, value) => 0.0);
      _statusLog = "Калибровка виртуального TPMS сброшена. Приняты текущие давления.";
    });
  }

  // ==================== ИНТЕРФЕЙС ДАШБОРДА ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('X-Trail T31 2.5 Control'),
        backgroundColor: const Color(0xFF1A1F29),
        actions: [
          IconButton(
            tooltip: 'Сброс калибровки TPMS',
            icon: const Icon(Icons.tire_repair),
            onPressed: _resetTpmsCalibration,
          ),
          IconButton(
            tooltip: 'Демо-режим',
            icon: Icon(_isDemoMode ? Icons.stop_circle : Icons.play_circle_fill,
                color: _isDemoMode ? Colors.amber : Colors.white),
            onPressed: _toggleDemoMode,
          ),
          IconButton(
            tooltip: 'Подключить ELM327',
            icon: Icon(Icons.bluetooth,
                color: _isConnected ? Colors.greenAccent : Colors.white),
            onPressed: _connectToElm,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            // Верхняя строка: Вариатор + Полный привод
            Row(
              children: [
                Expanded(child: _buildCvtCard()),
                const SizedBox(width: 12),
                Expanded(child: _buildAwdCard()),
              ],
            ),
            const SizedBox(height: 12),
            // Центральная часть: Шасси, пробуксовка колес и виртуальный TPMS
            Expanded(child: _buildChassisMonitor()),
            const SizedBox(height: 8),
            // Строка состояния
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _statusLog,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Виджет температуры вариатора JF011E с цветовой зоной
  Widget _buildCvtCard() {
    Color tempColor = Colors.greenAccent;
    String tempState = "НОРМА (Рабочая)";
    if (_telemetry.cvtTemp < 50) {
      tempColor = Colors.lightBlueAccent;
      tempState = "ХОЛОДНЫЙ (Прогрев)";
    } else if (_telemetry.cvtTemp >= 90 && _telemetry.cvtTemp < 105) {
      tempColor = Colors.orangeAccent;
      tempState = "НАГРЕВ (Счетчик > 90°C)";
    } else if (_telemetry.cvtTemp >= 105) {
      tempColor = Colors.redAccent;
      tempState = "ПЕРЕГРЕВ!";
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("ВАРИАТОР (CVT)",
                style: TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  "${_telemetry.cvtTemp.toStringAsFixed(0)}°C",
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: tempColor),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(tempState, style: TextStyle(fontSize: 12, color: tempColor)),
          ],
        ),
      ),
    );
  }

  // Виджет состояния полного привода All-Mode 4x4-i
  Widget _buildAwdCard() {
    int frontSplit = 100 - _telemetry.awdTorqueSplitRear;
    int rearSplit = _telemetry.awdTorqueSplitRear;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("4WD ПРИВОД",
                    style: TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.bold)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _telemetry.awdMode == "LOCK" ? Colors.amber.withOpacity(0.25) : Colors.blueGrey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _telemetry.awdMode,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _telemetry.awdMode == "LOCK" ? Colors.amber : Colors.cyanAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "$frontSplit : $rearSplit %",
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: rearSplit / 50.0,
              backgroundColor: Colors.white12,
              color: rearSplit > 25 ? Colors.amberAccent : Colors.cyanAccent,
              minHeight: 6,
            ),
            const SizedBox(height: 4),
            Text("Муфта: ${_telemetry.awdSolenoidCurrent.toStringAsFixed(2)} А",
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      ),
    );
  }

  // Схема шасси с 4 колесами (Пробуксовка + Виртуальный TPMS)
  Widget _buildChassisMonitor() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              "КОНТРОЛЬ ПРОБУКСОВКИ & ВИРТУАЛЬНЫЙ TPMS (ABS)",
              style: TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Левый борт (FL и RL)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildWheelWidget("FL", "Перед Лев", _telemetry.speedFL),
                      _buildWheelWidget("RL", "Зад Лев", _telemetry.speedRL),
                    ],
                  ),
                  // Центральная ось / Кардан и муфта
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.keyboard_double_arrow_up, color: Colors.white30, size: 28),
                      Container(
                        width: 6,
                        height: 90,
                        color: Colors.white24,
                      ),
                      // Индикатор зажатия электромагнитной муфты
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _telemetry.awdTorqueSplitRear > 10
                              ? Colors.amber.withOpacity(0.3)
                              : Colors.white10,
                          border: Border.all(
                            color: _telemetry.awdTorqueSplitRear > 10 ? Colors.amber : Colors.white24,
                            width: 2,
                          ),
                        ),
                        child: Text(
                          "${_telemetry.awdTorqueSplitRear}%",
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Container(
                        width: 6,
                        height: 60,
                        color: _telemetry.awdTorqueSplitRear > 5 ? Colors.amber : Colors.white24,
                      ),
                    ],
                  ),
                  // Правый борт (FR и RR)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildWheelWidget("FR", "Перед Прав", _telemetry.speedFR),
                      _buildWheelWidget("RR", "Зад Прав", _telemetry.speedRR),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Карточка отдельного колеса
  Widget _buildWheelWidget(String code, String label, double speed) {
    final bool isSlipping = _telemetry.wheelSlip[code] ?? false;
    final double slipPct = _telemetry.slipRatio[code] ?? 0.0;
    final String tpms = _telemetry.tpmsStatus[code] ?? 'OK';
    final double dev = _telemetry.tpmsDeviation[code] ?? 0.0;

    Color borderColor = Colors.white24;
    Color bgColor = const Color(0xFF262C3A);

    if (isSlipping) {
      borderColor = Colors.redAccent;
      bgColor = Colors.redAccent.withOpacity(0.25);
    } else if (tpms == 'LOW') {
      borderColor = Colors.amber;
      bgColor = Colors.amber.withOpacity(0.18);
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 135,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: isSlipping || tpms == 'LOW' ? 2.5 : 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
              if (isSlipping)
                const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 16)
              else if (tpms == 'LOW')
                const Icon(Icons.tire_repair, color: Colors.amber, size: 16)
              else
                const Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 14),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "${speed.toStringAsFixed(1)} км/ч",
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          // Индикация пробуксовки ИЛИ статуса виртуального TPMS
          if (isSlipping)
            Text(
              "БУКС +${slipPct.toStringAsFixed(0)}%",
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.redAccent),
            )
          else
            Text(
              tpms == 'LOW'
                  ? "Спущено! (+${dev.toStringAsFixed(2)}%)"
                  : "TPMS: Норма (${dev >= 0 ? '+' : ''}${dev.toStringAsFixed(2)}%)",
              style: TextStyle(
                fontSize: 11,
                color: tpms == 'LOW' ? Colors.amber : Colors.greenAccent,
              ),
            ),
        ],
      ),
    );
  }
}
