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

class DevLogEntry {
  final DateTime timestamp;
  final String direction;
  final String ecu;
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

  String lastRawAbs = "Нет данных";
  String lastRawAwd = "Нет данных";
  String lastRawCvt = "Нет данных";
  List<int> lastBytesAbs = [];
  List<int> lastBytesAwd = [];
  List<int> prevBytesAwd = [];
  List<int> lastBytesCvt = [];
  String activeAbsCommand = "Поиск...";
  String activeCvtCommand = "2101 (c 10C0)";

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
  bool _isPollingLoopRunning = false;
  bool _pausePollingForManualCmd = false;

  final CarTelemetry _telemetry = CarTelemetry();
  final List<DevLogEntry> _devLogs = [];
  final ValueNotifier<int> _logNotifier = ValueNotifier<int>(0);

  Timer? _demoTimer;
  String _rxBuffer = "";
  String _currentTargetEcu = "ELM";
  Completer<String>? _cmdCompleter;

  // Список кандидатов-команд для блока ABS (так как 2101 дал 7F2112, а 221101 дал 7F2211)
  final List<String> _absCandidateCmds = ["2102", "2103", "2104", "2110", "2120", "2105"];
  int _absCandidateIdx = 0;
  String? _workingAbsCmd;

  final Map<String, double> _tpmsAccumulator = {'FL': 0.0, 'FR': 0.0, 'RL': 0.0, 'RR': 0.0};
  int _tpmsSamplesCount = 0;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  @override
  void dispose() {
    _isPollingLoopRunning = false;
    _demoTimer?.cancel();
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
    if (_devLogs.length > 400) {
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

  // ==================== ПОДКЛЮЧЕНИЕ И СИНХРОННАЯ ОЧЕРЕДЬ ELM327 ====================

  Future<void> _connectToElm() async {
    try {
      await _requestPermissions();
      final List<BluetoothDevice> devices =
          await FlutterBluetoothSerial.instance.getBondedDevices();

      if (!mounted) return;

      if (devices.isEmpty) {
        _showPopupAlert(
          "Нет спаренных устройств",
          "Сначала выполните сопряжение с адаптером ELM327 в настройках Bluetooth телефона (обычно PIN 1234 или 0000).",
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

      _demoTimer?.cancel();
      _isPollingLoopRunning = false;
      _workingAbsCmd = null;

      _addDevLog("SYS", "BT", "Подключение к ${selectedDevice.name} (${selectedDevice.address})...");
      _connection = await BluetoothConnection.toAddress(selectedDevice.address);

      setState(() {
        _isConnected = true;
        _isDemoMode = false;
      });
      _addDevLog("SYS", "BT", "Подключено! Настройка протокола Nissan CAN...");

      _connection!.input!.listen(_onDataReceived).onDone(() {
        setState(() {
          _isConnected = false;
          _isPollingLoopRunning = false;
        });
        if (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
          _cmdCompleter!.complete("DISCONNECTED");
        }
        _showPopupAlert(
          "Связь потеряна",
          "Bluetooth-соединение с адаптером ELM327 было разорвано.",
          isError: true,
        );
      });

      await _initElm327();
      _runSequentialCanLoop();
    } catch (e, stack) {
      _showPopupAlert(
        "Ошибка подключения Bluetooth",
        "Не удалось подключиться к ELM327.\n\nДетали ошибки:\n$e\n\nСтек:\n$stack",
        isError: true,
      );
    }
  }

  Future<String> _sendAndWait(String cmd, {String ecuTag = "ELM", int timeoutMs = 1500}) async {
    if (_connection == null || !_isConnected) return "";

    while (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
      await Future.delayed(const Duration(milliseconds: 20));
    }

    _currentTargetEcu = ecuTag;
    _cmdCompleter = Completer<String>();
    _rxBuffer = "";

    try {
      _telemetry.txCount++;
      _addDevLog("TX ->", ecuTag, cmd);
      _connection!.output.add(Uint8List.fromList(utf8.encode("$cmd\r")));
      await _connection!.output.allSent;

      final String resp = await _cmdCompleter!.future.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () {
          _addDevLog("ERR", ecuTag, "TIMEOUT ($cmd)");
          return "TIMEOUT";
        },
      );
      await Future.delayed(const Duration(milliseconds: 15));
      return resp;
    } catch (e) {
      _addDevLog("ERR", ecuTag, "Ошибка отправки '$cmd': $e");
      return "ERROR";
    }
  }

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

      if (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
        _cmdCompleter!.complete(rawResponse);
      }
    }
  }

  Future<void> _initElm327() async {
    await _sendAndWait("AT Z", ecuTag: "INIT", timeoutMs: 2500);
    await Future.delayed(const Duration(milliseconds: 300));
    await _sendAndWait("AT E0", ecuTag: "INIT");
    await _sendAndWait("AT L0", ecuTag: "INIT");
    await _sendAndWait("AT S0", ecuTag: "INIT");
    await _sendAndWait("AT H0", ecuTag: "INIT");
    await _sendAndWait("AT CAF1", ecuTag: "INIT");
    await _sendAndWait("AT SP 6", ecuTag: "INIT");
    await _sendAndWait("AT ST 32", ecuTag: "INIT");
  }

  Future<void> _selectEcu(String txHeader, String rxFilter, String ecuTag) async {
    await _sendAndWait("AT SH $txHeader", ecuTag: ecuTag);
    await _sendAndWait("AT CRA $rxFilter", ecuTag: ecuTag);
    await _sendAndWait("AT FCSH $txHeader", ecuTag: ecuTag);
    await _sendAndWait("AT FCSD 300000", ecuTag: ecuTag);
    await _sendAndWait("AT FCSM 1", ecuTag: ecuTag);
  }

  // ==================== ПОСЛЕДОВАТЕЛЬНЫЙ ЦИКЛ ОПРОСА БЛОКОВ v3 ====================

  Future<void> _runSequentialCanLoop() async {
    if (_isPollingLoopRunning) return;
    _isPollingLoopRunning = true;

    while (_isConnected && _isPollingLoopRunning) {
      if (_pausePollingForManualCmd) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      // 1. БЛОК ПОЛНОГО ПРИВОДА 4WD (743 -> 763) — стабильно отдает 104 байта!
      await _selectEcu("743", "763", "4WD");
      final String awdResp = await _sendAndWait("2101", ecuTag: "4WD");
      _parseMultiFrameResponse(awdResp, "4WD");

      if (!_isConnected || !_isPollingLoopRunning) break;

      // 2. БЛОК ВАРИАТОРА JF011E (7E1 -> 7E9)
      // Исправление ошибки 7F 21 80: сначала открываем сессию 10C0!
      await _selectEcu("7E1", "7E9", "CVT");
      await _sendAndWait("10C0", ecuTag: "CVT");
      String cvtResp = await _sendAndWait("2101", ecuTag: "CVT");
      if (cvtResp.contains("7F")) {
        // Если 2101 все еще закрыт, пробуем 2102 или чтение через OBD-режим
        _telemetry.activeCvtCommand = "2102 (c 10C0)";
        cvtResp = await _sendAndWait("2102", ecuTag: "CVT");
      } else {
        _telemetry.activeCvtCommand = "2101 (c 10C0)";
      }
      _parseMultiFrameResponse(cvtResp, "CVT");

      if (!_isConnected || !_isPollingLoopRunning) break;

      // 3. БЛОК ABS (740 -> 760) — автопоиск рабочей группы 21 XX
      await _selectEcu("740", "760", "ABS");
      await _sendAndWait("10C0", ecuTag: "ABS");
      final String cmdToTry = _workingAbsCmd ?? _absCandidateCmds[_absCandidateIdx];
      _telemetry.activeAbsCommand = cmdToTry;
      final String absResp = await _sendAndWait(cmdToTry, ecuTag: "ABS");

      if (!absResp.contains("7F") && !absResp.contains("NO DATA") && absResp.contains("61")) {
        // Нашли рабочую команду ABS! Фиксируем её
        _workingAbsCmd = cmdToTry;
        _parseMultiFrameResponse(absResp, "ABS");
      } else {
        // Переключаем кандидата на следующий цикл
        _telemetry.errCount++;
        setState(() {
          _telemetry.lastRawAbs = "$cmdToTry -> $absResp";
        });
        _absCandidateIdx = (_absCandidateIdx + 1) % _absCandidateCmds.length;
      }

      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  // ==================== ПАРСИНГ ОТВЕТОВ NISSAN T31 ====================

  String _stripIsoTpFraming(String rawStr) {
    final tokens = rawStr.split(RegExp(r'\s+'));
    final StringBuffer hexBuf = StringBuffer();
    for (final t in tokens) {
      if (t.isEmpty) continue;
      if (RegExp(r'^[0-9A-Fa-f]:$').hasMatch(t)) continue;
      if (t.length == 3 && RegExp(r'^[0-9A-Fa-f]{3}$').hasMatch(t)) continue;
      String cleanedToken = t.replaceAll(RegExp(r'[0-9A-Fa-f]:'), '');
      hexBuf.write(cleanedToken);
    }
    return hexBuf.toString();
  }

  void _parseMultiFrameResponse(String rawStr, String ecuTag) {
    if (rawStr.isEmpty) return;
    if (rawStr.contains("NO DATA") || rawStr.contains("ERROR") || rawStr.contains("7F")) {
      _telemetry.errCount++;
      setState(() {
        if (ecuTag == "4WD") _telemetry.lastRawAwd = rawStr;
        if (ecuTag == "CVT") _telemetry.lastRawCvt = rawStr;
        if (ecuTag == "ABS") _telemetry.lastRawAbs = rawStr;
      });
      return;
    }

    final String cleanHex = _stripIsoTpFraming(rawStr);
    final List<int> bytes = _hexToBytes(cleanHex);

    // Ищем позитивный заголовок ответа 0x61 (ответ на сервис 21)
    int startIdx = -1;
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x61) {
        startIdx = i;
        break;
      }
    }

    if (startIdx == -1) return;
    final List<int> payload = bytes.sublist(startIdx);

    setState(() {
      if (ecuTag == "4WD") {
        _telemetry.lastRawAwd = rawStr;
        if (_telemetry.lastBytesAwd.isNotEmpty) {
          _telemetry.prevBytesAwd = List<int>.from(_telemetry.lastBytesAwd);
        }
        _telemetry.lastBytesAwd = payload;
        _parseAwdData(payload);
      } else if (ecuTag == "CVT") {
        _telemetry.lastRawCvt = rawStr;
        _telemetry.lastBytesCvt = payload;
        _parseCvtData(payload);
      } else if (ecuTag == "ABS") {
        _telemetry.lastRawAbs = rawStr;
        _telemetry.lastBytesAbs = payload;
        _parseAbsPackage(payload);
      }
      _calculateSlipAndVirtualTpms();
    });
  }

  // Парсинг 104-байтного пакета 4WD (743 -> 763), адаптированный под реальный дамп T31
  void _parseAwdData(List<int> b) {
    if (b.length < 40) return;

    // Если блок ABS еще ищет команду, берем скорости колес прямо из первых байтов 4WD (байты 2..5 или 2..9)
    if (_workingAbsCmd == null) {
      // В стоячем положении на твоем логе байты [2]..[8] строго равны 00
      _telemetry.speedFL = b[2].toDouble();
      _telemetry.speedFR = b[3].toDouble();
      _telemetry.speedRL = b[4].toDouble();
      _telemetry.speedRR = b[5].toDouble();
    }

    // Байт [28] в твоем дампе равен 0x04 (битовая маска режима шайбы 4WD)
    int modeFlags = b[28];
    if (modeFlags == 0x02 || modeFlags == 0x01) {
      _telemetry.awdMode = "2WD";
    } else if (modeFlags >= 0x08) {
      _telemetry.awdMode = "LOCK";
    } else {
      _telemetry.awdMode = "AUTO";
    }

    // Ток муфты / процент блокировки (в стоячем положении байты [6..7] = 00 00)
    int rawTorque = b[6];
    _telemetry.awdTorqueSplitRear = rawTorque.clamp(0, 50);
    _telemetry.awdSolenoidCurrent = (_telemetry.awdTorqueSplitRear / 50.0) * 2.8;
  }

  void _parseAbsPackage(List<int> b) {
    if (b.length >= 10) {
      _telemetry.speedFL = ((b[2] << 8) + b[3]) / 100.0;
      _telemetry.speedFR = ((b[4] << 8) + b[5]) / 100.0;
      _telemetry.speedRL = ((b[6] << 8) + b[7]) / 100.0;
      _telemetry.speedRR = ((b[8] << 8) + b[9]) / 100.0;
    }
  }

  void _parseCvtData(List<int> b) {
    // В пакете 61 01 от Jatco JF011E проверяем стандартные смещения температуры
    if (b.length >= 12) {
      int rawTemp = b[10];
      _telemetry.cvtTemp = (rawTemp - 50).toDouble();
    } else if (b.length >= 5) {
      _telemetry.cvtTemp = (b[4] - 50).toDouble();
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
    final clean = hex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    for (int i = 0; i + 1 < clean.length; i += 2) {
      final part = clean.substring(i, i + 2);
      final val = int.tryParse(part, radix: 16);
      if (val != null) bytes.add(val);
    }
    return bytes;
  }

  // ==================== СИМУЛЯТОР (ДЕМО-РЕЖИМ) ====================

  void _toggleDemoMode() {
    _demoTimer?.cancel();
    setState(() {
      _isDemoMode = !_isDemoMode;
    });

    if (_isDemoMode) {
      _addDevLog("SYS", "DEMO", "Запущен демо-режим");
      int tick = 0;
      _demoTimer = Timer.periodic(const Duration(milliseconds: 350), (t) {
        tick++;
        bool simulateSlip = (tick % 20) < 6;
        setState(() {
          _telemetry.speedRL = 60.0;
          _telemetry.speedRR = 60.45;
          _telemetry.speedFR = 60.0;
          _telemetry.speedFL = simulateSlip ? 68.5 : 60.0;
          _telemetry.cvtTemp = 82.0;
          _telemetry.awdMode = "AUTO";
          _telemetry.awdTorqueSplitRear = simulateSlip ? 45 : 5;
          _telemetry.awdSolenoidCurrent = simulateSlip ? 2.4 : 0.2;
          _calculateSlipAndVirtualTpms();
        });
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
      "Текущие радиусы качения всех 4 колес приняты за эталон.",
      isError: false,
    );
  }

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
            await _sendAndWait(cmd, ecuTag: "MANUAL", timeoutMs: 2000);
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
              'by denmov (v3)',
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

// ==================== ЭКРАН МЕНЮ РАЗРАБОТЧИКА v3 ====================

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

  String _formatDiffAwdBytes() {
    final cur = widget.telemetry.lastBytesAwd;
    final prev = widget.telemetry.prevBytesAwd;
    if (cur.isEmpty || prev.isEmpty || cur.length != prev.length) return "Нет изменений";
    List<String> diffs = [];
    for (int i = 0; i < cur.length; i++) {
      if (cur[i] != prev[i]) {
        diffs.add("[$i]: ${prev[i].toRadixString(16).toUpperCase()}->${cur[i].toRadixString(16).toUpperCase()}");
      }
    }
    return diffs.isEmpty ? "Стабильно" : diffs.join(", ");
  }

  void _copyAllTelemetryReport() {
    final StringBuffer sb = StringBuffer();
    sb.writeln("=== X-TRAIL T31 DIAGNOSTIC REPORT v3 (by denmov) ===");
    sb.writeln("TX: ${widget.telemetry.txCount} | RX: ${widget.telemetry.rxCount} | ERR: ${widget.telemetry.errCount}");
    sb.writeln("\n--- СНИМКИ БЛОКОВ (RAW HEX) ---");
    sb.writeln("ABS (${widget.telemetry.activeAbsCommand}): ${widget.telemetry.lastRawAbs}");
    sb.writeln("ABS BYTES: ${_formatIndexedBytes(widget.telemetry.lastBytesAbs)}");
    sb.writeln("4WD (743->763): ${widget.telemetry.lastRawAwd}");
    sb.writeln("4WD DIFF: ${_formatDiffAwdBytes()}");
    sb.writeln("4WD BYTES: ${_formatIndexedBytes(widget.telemetry.lastBytesAwd)}");
    sb.writeln("CVT (${widget.telemetry.activeCvtCommand}): ${widget.telemetry.lastRawCvt}");
    sb.writeln("CVT BYTES: ${_formatIndexedBytes(widget.telemetry.lastBytesCvt)}");
    sb.writeln("\n--- ПОСЛЕДНИЕ 60 СТРОК ЛОГА ---");
    for (final entry in widget.logs.take(60)) {
      sb.writeln(entry.toString());
    }

    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Полный отчет разработчика v3 скопирован в буфер!"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  String _formatIndexedBytes(List<int> bytes) {
    if (bytes.isEmpty) return "Пусто";
    List<String> parts = [];
    for (int i = 0; i < bytes.length; i++) {
      final hex = bytes[i].toRadixString(16).toUpperCase().padLeft(2, '0');
      parts.add("[$i]:$hex(${bytes[i]})");
    }
    return parts.join(" ");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F29),
        title: const Text("Меню разработчика v3", style: TextStyle(fontSize: 16)),
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
                _buildCounterItem("Ошибки/7F", widget.telemetry.errCount, Colors.redAccent),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildEcuDebugCard(
          title: "Вариатор Jatco JF011E (7E1 -> 7E9) | ${widget.telemetry.activeCvtCommand}",
          rawHex: widget.telemetry.lastRawCvt,
          indexedBytes: _formatIndexedBytes(widget.telemetry.lastBytesCvt),
          parsedSummary: "Температура CVT: ${widget.telemetry.cvtTemp} °C",
          formulaNote: "Добавлена сессия 10C0 перед 2101 для снятия блокировки 7F 21 80.",
        ),
        const SizedBox(height: 8),
        _buildEcuDebugCard(
          title: "Блок 4WD (743 -> 763) | Пакет 104 байта OK!",
          rawHex: widget.telemetry.lastRawAwd,
          indexedBytes: _formatIndexedBytes(widget.telemetry.lastBytesAwd),
          parsedSummary:
              "Режим: ${widget.telemetry.awdMode} | Момент назад: ${widget.telemetry.awdTorqueSplitRear}%\n"
              "Изменившиеся байты: ${_formatDiffAwdBytes()}",
          formulaNote: "Поверни шайбу 2WD/AUTO/LOCK и посмотри в строку 'Изменившиеся байты'.",
        ),
        const SizedBox(height: 8),
        _buildEcuDebugCard(
          title: "Блок ABS (740 -> 760) | Автопоиск: ${widget.telemetry.activeAbsCommand}",
          rawHex: widget.telemetry.lastRawAbs,
          indexedBytes: _formatIndexedBytes(widget.telemetry.lastBytesAbs),
          parsedSummary:
              "FL: ${widget.telemetry.speedFL} км/ч | FR: ${widget.telemetry.speedFR} км/ч\n"
              "RL: ${widget.telemetry.speedRL} км/ч | RR: ${widget.telemetry.speedRR} км/ч",
          formulaNote: "Перебирает группы 2102, 2103, 2104, 2110, 2120.",
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
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.greenAccent),
            ),
            const SizedBox(height: 6),
            const Text("Раскладка по индексам [индекс]:HEX(DEC):",
                style: TextStyle(fontSize: 11, color: Colors.white54)),
            SelectableText(
              indexedBytes,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white),
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
              _buildQuickCmdChip("Сессия 10C0", "10C0"),
              _buildQuickCmdChip("Запрос 2101", "2101"),
              _buildQuickCmdChip("Запрос 2102", "2102"),
              _buildQuickCmdChip("Запрос 2103", "2103"),
              _buildQuickCmdChip("Запрос 2110", "2110"),
              _buildQuickCmdChip("Напряжение (AT RV)", "AT RV"),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  decoration: const InputDecoration(
                    hintText: "Введите команду (например: 2102)",
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
