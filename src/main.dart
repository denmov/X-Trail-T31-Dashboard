import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const XTrailT31DashboardApp());
}

class XTrailT31DashboardApp extends StatelessWidget {
  const XTrailT31DashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'X-Trail T31 CAN Monitor by denmov',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF12151C),
        cardColor: const Color(0xFF1E232E),
      ),
      home: const DashboardScreen(),
    );
  }
}

// Запись в журнале разработчика
class DevLogEntry {
  final DateTime timestamp;
  final String direction; // "TX", "RX", "SYS", "ERR"
  final String ecu;       // "ABS", "4WD", "CVT", "ELM"
  final String message;

  DevLogEntry({
    required this.timestamp,
    required this.direction,
    required this.ecu,
    required this.message,
  });

  String get formattedTime =>
      "${timestamp.hour.toString().padLeft(2, '0')}:"
      "${timestamp.minute.toString().padLeft(2, '0')}:"
      "${timestamp.second.toString().padLeft(2, '0')}."
      "${(timestamp.millisecond ~/ 10).toString().padLeft(2, '0')}";

  @override
  String toString() => "[$formattedTime] [$ecu] $direction: $message";
}

// Модель данных состояния автомобиля и отладочных снимков
class CarTelemetry {
  double speedFL = 0.0;
  double speedFR = 0.0;
  double speedRL = 0.0;
  double speedRR = 0.0;

  double cvtTemp = 0.0;

  String awdMode = "AUTO";
  int awdTorqueSplitRear = 0;
  double awdSolenoidCurrent = 0.0;

  Map<String, bool> wheelSlip = {'FL': false, 'FR': false, 'RL': false, 'RR': false};
  Map<String, double> slipRatio = {'FL': 0.0, 'FR': 0.0, 'RL': 0.0, 'RR': 0.0};

  Map<String, String> tpmsStatus = {'FL': 'OK', 'FR': 'OK', 'RL': 'OK', 'RR': 'OK'};
  Map<String, double> tpmsDeviation = {'FL': 0.0, 'FR': 0.0, 'RL': 0.0, 'RR': 0.0};

  // Отладочные данные для Меню Разработчика
  String lastRawAbs = "Нет данных";
  String lastRawAwd = "Нет данных";
  String lastRawCvt = "Нет данных";
  List<int> lastBytesAbs = [];
  List<int> lastBytesAwd = [];
  List<int> lastBytesCvt = [];
  int txCount = 0;
  int rxCount = 0;
  int errCount = 0;
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
  bool _pausePollingForManualCmd = false;

  final CarTelemetry _telemetry = CarTelemetry();
  final List<DevLogEntry> _devLogs = [];
  final ValueNotifier<int> _logNotifier = ValueNotifier<int>(0);

  Timer? _pollingTimer;
  int _pollStep = 0;
  String _rxBuffer = "";
  String _currentTargetEcu = "ELM";

  final Map<String, double> _tpmsAccumulator = {'FL': 0.0, 'FR': 0.0, 'RL': 0.0, 'RR': 0.0};
  int _tpmsSamplesCount = 0;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _connection?.dispose();
    _logNotifier.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  // Добавление строки в журнал разработчика
  void _addDevLog(String direction, String ecu, String message) {
    _devLogs.insert(
      0,
      DevLogEntry(
        timestamp: DateTime.now(),
        direction: direction,
        ecu: ecu,
        message: message,
      ),
    );
    if (_devLogs.length > 300) {
      _devLogs.removeLast();
    }
    _logNotifier.value++;
  }

  // ==================== ВСПЛЫВАЮЩЕЕ ОКНО ОШИБОК И УВЕДОМЛЕНИЙ ====================

  void _showPopupAlert(String title, String details, {bool isError = true}) {
    _addDevLog(isError ? "ERR" : "SYS", "APP", "$title: $details");
    if (isError) _telemetry.errCount++;

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E232E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: isError ? Colors.redAccent : Colors.cyanAccent,
            width: 1.5,
          ),
        ),
        title: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              color: isError ? Colors.redAccent : Colors.cyanAccent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(
            child: SelectableText(
              details,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: Colors.white70,
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18, color: Colors.amberAccent),
            label: const Text("Копировать", style: TextStyle(color: Colors.amberAccent)),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: "$title\n$details"));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Скопировано в буфер обмена"),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isError ? Colors.redAccent : Colors.cyan,
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("ОК", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ==================== ПОДКЛЮЧЕНИЕ И ИНИЦИАЛИЗАЦИЯ ELM327 ====================

  Future<void> _connectToElm() async {
    try {
      await _requestPermissions();
      final List<BluetoothDevice> devices =
          await FlutterBluetoothSerial.instance.getBondedDevices();

      if (!mounted) return;

      if (devices.isEmpty) {
        _showPopupAlert(
          "Нет спаренных устройств",
          "Сначала выполните сопряжение с адаптером ELM327 в настройках Bluetooth телефона (обычно PIN 1234 или 0000), а также проверьте разрешение «Устройства поблизости».",
          isError: false,
        );
        return;
      }

      final BluetoothDevice? selectedDevice = await showDialog<BluetoothDevice>(
        context: context,
        builder: (context) => SimpleDialog(
          backgroundColor: const Color(0xFF1E232E),
          title: const Text('Выберите ELM327 (v1.5)'),
          children: devices
              .map((d) => SimpleDialogOption(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                      child: Text("${d.name ?? 'Неизвестно'} (${d.address})"),
                    ),
                    onPressed: () => Navigator.pop(context, d),
                  ))
              .toList(),
        ),
      );

      if (selectedDevice == null) return;

      _addDevLog("SYS", "BT", "Подключение к ${selectedDevice.name} (${selectedDevice.address})...");
      _connection = await BluetoothConnection.toAddress(selectedDevice.address);

      setState(() {
        _isConnected = true;
        _isDemoMode = false;
      });
      _addDevLog("SYS", "BT", "Успешно подключено! Инициализация ELM327...");

      _connection!.input!.listen(_onDataReceived).onDone(() {
        setState(() {
          _isConnected = false;
        });
        _pollingTimer?.cancel();
        _showPopupAlert(
          "Связь потеряна",
          "Bluetooth-соединение с адаптером ELM327 было разорвано.",
          isError: true,
        );
      });

      await _initElm327();
      _startCanPolling();
    } catch (e, stack) {
      _showPopupAlert(
        "Ошибка подключения Bluetooth",
        "Не удалось подключиться к ELM327.\n\nДетали ошибки:\n$e\n\nСтек:\n$stack",
        isError: true,
      );
    }
  }

  Future<void> _sendCommand(String cmd, {int delayMs = 110, String ecuTag = "ELM"}) async {
    if (_connection != null && _isConnected) {
      try {
        _currentTargetEcu = ecuTag;
        _telemetry.txCount++;
        _addDevLog("TX ->", ecuTag, cmd);
        _connection!.output.add(Uint8List.fromList(utf8.encode("$cmd\r")));
        await _connection!.output.allSent;
        await Future.delayed(Duration(milliseconds: delayMs));
      } catch (e) {
        _addDevLog("ERR", ecuTag, "Ошибка отправки '$cmd': $e");
      }
    }
  }

  Future<void> _initElm327() async {
    await _sendCommand("AT Z", delayMs: 500, ecuTag: "INIT");
    await _sendCommand("AT E0", ecuTag: "INIT");
    await _sendCommand("AT L0", ecuTag: "INIT");
    await _sendCommand("AT S0", ecuTag: "INIT");
    await _sendCommand("AT H0", ecuTag: "INIT");
    await _sendCommand("AT SP 6", ecuTag: "INIT"); // ISO 15765-4 CAN (11 bit ID, 500 kbaud)
  }

  // ==================== ЦИКЛ ОПРОСА БЛОКОВ NISSAN X-TRAIL T31 ====================

  void _startCanPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      if (!_isConnected || _pausePollingForManualCmd) return;

      switch (_pollStep) {
        case 0:
          // Опрос блока ABS (740 -> 760)
          await _sendCommand("AT SH 740", delayMs: 40, ecuTag: "ABS");
          await _sendCommand("AT CRA 760", delayMs: 40, ecuTag: "ABS");
          await _sendCommand("2101", delayMs: 90, ecuTag: "ABS");
          break;
        case 1:
          // Опрос блока полного привода 4WD (743 -> 763)
          await _sendCommand("AT SH 743", delayMs: 40, ecuTag: "4WD");
          await _sendCommand("AT CRA 763", delayMs: 40, ecuTag: "4WD");
          await _sendCommand("2101", delayMs: 90, ecuTag: "4WD");
          break;
        case 2:
          // Повторный опрос ABS для высокой частоты детекции букса
          await _sendCommand("AT SH 740", delayMs: 40, ecuTag: "ABS");
          await _sendCommand("AT CRA 760", delayMs: 40, ecuTag: "ABS");
          await _sendCommand("2101", delayMs: 90, ecuTag: "ABS");
          break;
        case 3:
          // Опрос вариатора Jatco JF011E (7E1 -> 7E9)
          await _sendCommand("AT SH 7E1", delayMs: 40, ecuTag: "CVT");
          await _sendCommand("AT CRA 7E9", delayMs: 40, ecuTag: "CVT");
          await _sendCommand("2101", delayMs: 90, ecuTag: "CVT");
          break;
      }

      _pollStep = (_pollStep + 1) % 4;
    });
  }

  // ==================== ПАРСИНГ ОТВЕТОВ И МАТЕМАТИКА ====================

  void _onDataReceived(Uint8List data) {
    _rxBuffer += ascii.decode(data, allowInvalid: true);
    if (_rxBuffer.contains(">")) {
      final String rawResponse = _rxBuffer
          .replaceAll("\r", " ")
          .replaceAll("\n", " ")
          .replaceAll(">", "")
          .trim();
      _rxBuffer = "";

      _telemetry.rxCount++;
      _addDevLog("RX <-", _currentTargetEcu, rawResponse.isEmpty ? "EMPTY" : rawResponse);
      _parseCanFrame(rawResponse, _currentTargetEcu);
    }
  }

  void _parseCanFrame(String rawStr, String ecuTag) {
    if (rawStr.isEmpty) return;
    if (rawStr.contains("NO DATA") || rawStr.contains("ERROR") || rawStr.contains("?")) {
      _telemetry.errCount++;
      return;
    }

    // Очищаем пробелы и префиксы многокадровых ответов ISO-TP (0:, 1:, 2: и первого кадра длины)
    final String noSpaces = rawStr.replaceAll(" ", "");
    final String cleanHex = noSpaces.replaceAll(RegExp(r'[0-9A-F]:'), '');
    final List<int> bytes = _hexToBytes(cleanHex);

    // Ищем начало позитивного ответа 61 01 (0x61, 0x01) в массиве байтов
    int startIdx = -1;
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x61 && bytes[i + 1] == 0x01) {
        startIdx = i;
        break;
      }
    }

    if (startIdx == -1) return;
    final List<int> payload = bytes.sublist(startIdx);

    setState(() {
      if (ecuTag == "ABS") {
        _telemetry.lastRawAbs = rawStr;
        _telemetry.lastBytesAbs = payload;
        _parseAbsData(payload);
      } else if (ecuTag == "4WD") {
        _telemetry.lastRawAwd = rawStr;
        _telemetry.lastBytesAwd = payload;
        _parseAwdData(payload);
      } else if (ecuTag == "CVT") {
        _telemetry.lastRawCvt = rawStr;
        _telemetry.lastBytesCvt = payload;
        _parseCvtData(payload);
      }
      _calculateSlipAndVirtualTpms();
    });
  }

  void _parseAbsData(List<int> b) {
    if (b.length >= 10) {
      _telemetry.speedFL = ((b[2] << 8) + b[3]) / 100.0;
      _telemetry.speedFR = ((b[4] << 8) + b[5]) / 100.0;
      _telemetry.speedRL = ((b[6] << 8) + b[7]) / 100.0;
      _telemetry.speedRR = ((b[8] << 8) + b[9]) / 100.0;
    }
  }

  void _parseAwdData(List<int> b) {
    if (b.length >= 6) {
      int currentMa = (b[2] << 8) + b[3];
      _telemetry.awdSolenoidCurrent = currentMa / 1000.0;
      _telemetry.awdTorqueSplitRear =
          ((_telemetry.awdSolenoidCurrent / 2.8) * 50).clamp(0, 50).round();

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

  void _parseCvtData(List<int> b) {
    if (b.length >= 12) {
      int rawTemp = b[10];
      _telemetry.cvtTemp = (rawTemp - 50).toDouble();
    }
  }

  void _calculateSlipAndVirtualTpms() {
    final Map<String, double> speeds = {
      'FL': _telemetry.speedFL,
      'FR': _telemetry.speedFR,
      'RL': _telemetry.speedRL,
      'RR': _telemetry.speedRR,
    };

    double vRef = speeds.values.reduce(min);
    double vAvg = speeds.values.reduce((a, b) => a + b) / 4.0;
    bool anySlip = false;

    speeds.forEach((wheel, speed) {
      double diff = speed - vRef;
      if (vRef > 3.0 && diff > 2.5) {
        _telemetry.wheelSlip[wheel] = true;
        _telemetry.slipRatio[wheel] = ((diff / vRef) * 100).clamp(0.0, 999.0);
        anySlip = true;
      } else if (vRef <= 3.0 && speed > 4.0) {
        _telemetry.wheelSlip[wheel] = true;
        _telemetry.slipRatio[wheel] = 100.0;
        anySlip = true;
      } else {
        _telemetry.wheelSlip[wheel] = false;
        _telemetry.slipRatio[wheel] = 0.0;
      }
    });

    double leftRightDiff =
        ((_telemetry.speedFL + _telemetry.speedRL) - (_telemetry.speedFR + _telemetry.speedRR)).abs();
    bool isGoingStraight = leftRightDiff < 0.8;

    if (!anySlip && isGoingStraight && vAvg > 40.0 && vAvg < 110.0) {
      _tpmsSamplesCount++;
      speeds.forEach((wheel, speed) {
        double devPercent = ((speed - vAvg) / vAvg) * 100.0;
        _tpmsAccumulator[wheel] = (_tpmsAccumulator[wheel]! * 0.95) + (devPercent * 0.05);
        _telemetry.tpmsDeviation[wheel] = _tpmsAccumulator[wheel]!;

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

  // ==================== СИМУЛЯТОР (ДЕМО-РЕЖИМ) ====================

  void _toggleDemoMode() {
    _pollingTimer?.cancel();
    setState(() {
      _isDemoMode = !_isDemoMode;
    });

    if (_isDemoMode) {
      _addDevLog("SYS", "DEMO", "Запущен демо-режим (симуляция CAN пакетов)");
      int tick = 0;
      _pollingTimer = Timer.periodic(const Duration(milliseconds: 350), (t) {
        tick++;
        bool simulateSlip = (tick % 20) < 6;

        // Генерируем правдоподобные сырые ответы для проверки меню разработчика
        _parseCanFrame(
          simulateSlip
              ? "61 01 1A C2 17 70 17 70 17 8C"
              : "61 01 17 70 17 70 17 70 17 8C",
          "ABS",
        );
        _parseCanFrame(
          simulateSlip ? "61 01 09 60 01 00" : "61 01 00 C8 01 00",
          "4WD",
        );
        _parseCanFrame("61 01 00 00 00 00 00 00 00 00 84 00", "CVT");
      });
    } else {
      _addDevLog("SYS", "DEMO", "Демо-режим остановлен");
    }
  }

  void _resetTpmsCalibration() {
    setState(() {
      _tpmsSamplesCount = 0;
      _tpmsAccumulator.updateAll((key, value) => 0.0);
      _telemetry.tpmsStatus.updateAll((key, value) => 'OK');
      _telemetry.tpmsDeviation.updateAll((key, value) => 0.0);
    });
    _showPopupAlert(
      "Калибровка TPMS сброшена",
      "Текущие радиусы качения всех 4 колес приняты за эталон. Проедьте 2-3 км по прямой со скоростью 40-100 км/ч для набора статистики.",
      isError: false,
    );
  }

  // ==================== ОТКРЫТИЕ МЕНЮ РАЗРАБОТЧИКА ====================

  void _openDeveloperMenu() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => DeveloperMenuScreen(
          telemetry: _telemetry,
          logs: _devLogs,
          logNotifier: _logNotifier,
          isConnected: _isConnected,
          onSendManualCommand: (String cmd) async {
            _pausePollingForManualCmd = true;
            await Future.delayed(const Duration(milliseconds: 150));
            await _sendCommand(cmd, delayMs: 250, ecuTag: "MANUAL");
            _pausePollingForManualCmd = false;
          },
          onClearLogs: () {
            setState(() {
              _devLogs.clear();
              _telemetry.txCount = 0;
              _telemetry.rxCount = 0;
              _telemetry.errCount = 0;
            });
            _logNotifier.value++;
          },
        ),
      ),
    );
  }

  // ==================== ГЛАВНЫЙ ЭКРАН ДАШБОРДА ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F29),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'X-Trail T31 2.5 Control',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            Text(
              'by denmov',
              style: TextStyle(
                fontSize: 11,
                color: Colors.cyanAccent,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Меню разработчика (Отладка CAN)',
            icon: const Icon(Icons.bug_report, color: Colors.amberAccent),
            onPressed: _openDeveloperMenu,
          ),
          IconButton(
            tooltip: 'Сброс калибровки TPMS',
            icon: const Icon(Icons.tire_repair),
            onPressed: _resetTpmsCalibration,
          ),
          IconButton(
            tooltip: 'Демо-режим',
            icon: Icon(
              _isDemoMode ? Icons.stop_circle : Icons.play_circle_fill,
              color: _isDemoMode ? Colors.amber : Colors.white,
            ),
            onPressed: _toggleDemoMode,
          ),
          IconButton(
            tooltip: 'Подключить ELM327',
            icon: Icon(
              Icons.bluetooth,
              color: _isConnected ? Colors.greenAccent : Colors.white,
            ),
            onPressed: _connectToElm,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: _buildCvtCard()),
                const SizedBox(width: 12),
                Expanded(child: _buildAwdCard()),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildChassisMonitor()),
          ],
        ),
      ),
    );
  }

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
            const Text(
              "ВАРИАТОР (CVT)",
              style: TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              "${_telemetry.cvtTemp.toStringAsFixed(0)}°C",
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: tempColor),
            ),
            const SizedBox(height: 4),
            Text(tempState, style: TextStyle(fontSize: 12, color: tempColor)),
          ],
        ),
      ),
    );
  }

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
                const Text(
                  "4WD ПРИВОД",
                  style: TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.bold),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _telemetry.awdMode == "LOCK"
                        ? Colors.amber.withOpacity(0.25)
                        : Colors.blueGrey.withOpacity(0.3),
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
            Text(
              "Муфта: ${_telemetry.awdSolenoidCurrent.toStringAsFixed(2)} А",
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

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
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildWheelWidget("FL", "Перед Лев", _telemetry.speedFL),
                      _buildWheelWidget("RL", "Зад Лев", _telemetry.speedRL),
                    ],
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.keyboard_double_arrow_up, color: Colors.white30, size: 28),
                      Container(width: 6, height: 80, color: Colors.white24),
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

// ==================== ЭКРАН МЕНЮ РАЗРАБОТЧИКА ====================

class DeveloperMenuScreen extends StatefulWidget {
  final CarTelemetry telemetry;
  final List<DevLogEntry> logs;
  final ValueNotifier<int> logNotifier;
  final bool isConnected;
  final Future<void> Function(String cmd) onSendManualCommand;
  final VoidCallback onClearLogs;

  const DeveloperMenuScreen({
    super.key,
    required this.telemetry,
    required this.logs,
    required this.logNotifier,
    required this.isConnected,
    required this.onSendManualCommand,
    required this.onClearLogs,
  });

  @override
  State<DeveloperMenuScreen> createState() => _DeveloperMenuScreenState();
}

class _DeveloperMenuScreenState extends State<DeveloperMenuScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _cmdController = TextEditingController();
  bool _pauseLiveLog = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _cmdController.dispose();
    super.dispose();
  }

  void _copyAllTelemetryReport() {
    final StringBuffer sb = StringBuffer();
    sb.writeln("=== X-TRAIL T31 DIAGNOSTIC REPORT (by denmov) ===");
    sb.writeln("TX: ${widget.telemetry.txCount} | RX: ${widget.telemetry.rxCount} | ERR: ${widget.telemetry.errCount}");
    sb.writeln("\n--- СНИМКИ БЛОКОВ (RAW HEX) ---");
    sb.writeln("ABS (740->760): ${widget.telemetry.lastRawAbs}");
    sb.writeln("4WD (743->763): ${widget.telemetry.lastRawAwd}");
    sb.writeln("CVT (7E1->7E9): ${widget.telemetry.lastRawCvt}");
    sb.writeln("\n--- ПОСЛЕДНИЕ 50 СТРОК ЛОГА ---");
    for (final entry in widget.logs.take(50)) {
      sb.writeln(entry.toString());
    }

    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Полный отчет разработчика скопирован в буфер!"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  String _formatIndexedBytes(List<int> bytes) {
    if (bytes.isEmpty) return "Пусто (ожидание ответа 61 01...)";
    List<String> parts = [];
    for (int i = 0; i < bytes.length; i++) {
      final hex = bytes[i].toRadixString(16).toUpperCase().padLeft(2, '0');
      parts.add("[$i]:$hex(${bytes[i]})");
    }
    return parts.join("  ");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F29),
        title: const Text("Меню разработчика", style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: "Скопировать весь отчет для Gemini",
            icon: const Icon(Icons.copy_all, color: Colors.amberAccent),
            onPressed: _copyAllTelemetryReport,
          ),
          IconButton(
            tooltip: "Очистить логи",
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: widget.onClearLogs,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.amberAccent,
          tabs: const [
            Tab(icon: Icon(Icons.memory, size: 18), text: "Сводка ЭБУ"),
            Tab(icon: Icon(Icons.list_alt, size: 18), text: "Живой лог"),
            Tab(icon: Icon(Icons.terminal, size: 18), text: "Терминал"),
          ],
        ),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: widget.logNotifier,
        builder: (context, _, __) {
          return TabBarView(
            controller: _tabController,
            children: [
              _buildEcuSnapshotTab(),
              _buildLiveLogTab(),
              _buildTerminalTab(),
            ],
          );
        },
      ),
    );
  }

  // Вкладка 1: Раскладка байтов по каждому блоку для быстрой правки формул
  Widget _buildEcuSnapshotTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildCounterItem("Отправлено (TX)", widget.telemetry.txCount, Colors.cyanAccent),
                _buildCounterItem("Принято (RX)", widget.telemetry.rxCount, Colors.greenAccent),
                _buildCounterItem("Ошибки/NO DATA", widget.telemetry.errCount, Colors.redAccent),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildEcuDebugCard(
          title: "Блок ABS (740 -> 760) | Запрос: 2101",
          rawHex: widget.telemetry.lastRawAbs,
          indexedBytes: _formatIndexedBytes(widget.telemetry.lastBytesAbs),
          parsedSummary:
              "FL: ${widget.telemetry.speedFL} км/ч | FR: ${widget.telemetry.speedFR} км/ч\n"
              "RL: ${widget.telemetry.speedRL} км/ч | RR: ${widget.telemetry.speedRR} км/ч",
          formulaNote: "Сейчас формула берет байты [2..3], [4..5], [6..7], [8..9] и делит на 100.",
        ),
        const SizedBox(height: 8),
        _buildEcuDebugCard(
          title: "Блок 4WD (743 -> 763) | Запрос: 2101",
          rawHex: widget.telemetry.lastRawAwd,
          indexedBytes: _formatIndexedBytes(widget.telemetry.lastBytesAwd),
          parsedSummary:
              "Режим: ${widget.telemetry.awdMode} | Ток муфты: ${widget.telemetry.awdSolenoidCurrent} А\n"
              "Момент назад: ${widget.telemetry.awdTorqueSplitRear}%",
          formulaNote: "Сейчас ток берется из [2..3] (мА), режим шайбы из [4].",
        ),
        const SizedBox(height: 8),
        _buildEcuDebugCard(
          title: "Вариатор Jatco JF011E (7E1 -> 7E9) | Запрос: 2101",
          rawHex: widget.telemetry.lastRawCvt,
          indexedBytes: _formatIndexedBytes(widget.telemetry.lastBytesCvt),
          parsedSummary: "Температура CVT: ${widget.telemetry.cvtTemp} °C",
          formulaNote: "Сейчас берется байт [10] - 50.",
        ),
      ],
    );
  }

  Widget _buildCounterItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60)),
      ],
    );
  }

  Widget _buildEcuDebugCard({
    required String title,
    required String rawHex,
    required String indexedBytes,
    required String parsedSummary,
    required String formulaNote,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.amberAccent,
              ),
            ),
            const Divider(color: Colors.white24),
            const Text("Сырой ответ адаптера:", style: TextStyle(fontSize: 11, color: Colors.white54)),
            SelectableText(
              rawHex,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.greenAccent),
            ),
            const SizedBox(height: 6),
            const Text("Раскладка по индексам [индекс]:HEX(DEC):",
                style: TextStyle(fontSize: 11, color: Colors.white54)),
            SelectableText(
              indexedBytes,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              "Результат парсера:\n$parsedSummary",
              style: const TextStyle(fontSize: 12, color: Colors.cyanAccent),
            ),
            const SizedBox(height: 4),
            Text(formulaNote, style: const TextStyle(fontSize: 11, color: Colors.white38)),
          ],
        ),
      ),
    );
  }

  // Вкладка 2: Живой журнал пакетов
  Widget _buildLiveLogTab() {
    return Column(
      children: [
        Container(
          color: Colors.black26,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Записей в буфере: ${widget.logs.length}",
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              TextButton.icon(
                icon: Icon(
                  _pauseLiveLog ? Icons.play_arrow : Icons.pause,
                  size: 16,
                  color: Colors.amberAccent,
                ),
                label: Text(
                  _pauseLiveLog ? "Возобновить" : "Пауза экрана",
                  style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                ),
                onPressed: () => setState(() => _pauseLiveLog = !_pauseLiveLog),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.logs.length,
            itemBuilder: (ctx, i) {
              final item = widget.logs[i];
              Color textColor = Colors.white70;
              if (item.direction.contains("TX")) textColor = Colors.cyanAccent;
              if (item.direction.contains("RX")) textColor = Colors.greenAccent;
              if (item.direction.contains("ERR")) textColor = Colors.redAccent;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: SelectableText(
                  item.toString(),
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: textColor),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Вкладка 3: Ручной терминал команд ELM327
  Widget _buildTerminalTab() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Быстрые диагностические команды:",
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildQuickCmdChip("Версия ELM (AT I)", "AT I"),
              _buildQuickCmdChip("Напряжение (AT RV)", "AT RV"),
              _buildQuickCmdChip("Протокол (AT DP)", "AT DP"),
              _buildQuickCmdChip("Шина ABS (AT SH 740)", "AT SH 740"),
              _buildQuickCmdChip("Шина 4WD (AT SH 743)", "AT SH 743"),
              _buildQuickCmdChip("Шина CVT (AT SH 7E1)", "AT SH 7E1"),
              _buildQuickCmdChip("Запрос 2101", "2101"),
              _buildQuickCmdChip("Запрос 221101", "221101"),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  decoration: const InputDecoration(
                    hintText: "Введите команду (например: 2101 или AT RV)",
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.amberAccent),
                onPressed: () {
                  final text = _cmdController.text.trim();
                  if (text.isNotEmpty) {
                    widget.onSendManualCommand(text);
                    _cmdController.clear();
                  }
                },
                child: const Text("Отправить", style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text("Ответы (последние 15):", style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView(
                children: widget.logs
                    .take(15)
                    .map((e) => Text(
                          e.toString(),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickCmdChip(String label, String cmd) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: const Color(0xFF262C3A),
      onPressed: () => widget.onSendManualCommand(cmd),
    );
  }
}
