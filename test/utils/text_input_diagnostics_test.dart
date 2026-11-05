import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/services/gamepad_service.dart';
import 'package:plezy/utils/app_logger.dart' as logging;
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/utils/text_input_diagnostics.dart';

void main() {
  const channel = MethodChannel('com.plezy/text_input');
  late Logger originalLogger;
  late List<String> lines;

  setUp(() {
    originalLogger = logging.appLogger;
    lines = [];
    logging.appLogger = Logger(printer: SimplePrinter(), output: _RecordingOutput(lines), filter: _AllFilter());
  });

  tearDown(() {
    logging.appLogger = originalLogger;
    TextInputDiagnostics.debugReset();
    TvDetectionService.setForceTVSync(false);
    GamepadService.debugNativeTextInputFocusHandler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  void mockPlatform({required bool diagnostics}) {
    GamepadService.debugNativeTextInputFocusHandler = (_) async {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isDiagnosticsEnabled') return diagnostics;
      return null;
    });
  }

  testWidgets('stays off unless the Android activity reports log.tag.PleziloTextInput', (tester) async {
    mockPlatform(diagnostics: false);
    await TextInputDiagnostics.loadPlatformSetting();
    expect(TextInputDiagnostics.enabled, isFalse);

    mockPlatform(diagnostics: true);
    await TextInputDiagnostics.loadPlatformSetting();
    expect(TextInputDiagnostics.enabled, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a TV field logs the values IME edits give it, lengths only', (tester) async {
    await TvDetectionService.getInstance(forceTv: true);
    TvDetectionService.setForceTVSync(true);
    mockPlatform(diagnostics: true);
    await TextInputDiagnostics.loadPlatformSetting();

    final controller = TextEditingController();
    final focusNode = FocusNode(debugLabel: 'voice_field');
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusableTextField(controller: controller, focusNode: focusNode),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();

    // What Gboard's dictation sends: composing partials, then the commit.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'secret words',
        selection: TextSelection.collapsed(offset: 12),
        composing: TextRange(start: 0, end: 12),
      ),
    );
    await tester.pump();

    expect(controller.text, 'secret words');
    expect(lines.any((line) => line.contains('Host.beginNativeTextInput node=voice_field')), isTrue);
    expect(
      lines.any(
        (line) =>
            line.contains('Host.controllerValue node=voice_field textLength=12') &&
            line.contains('composing=0-12') &&
            line.contains('readOnly=false'),
      ),
      isTrue,
      reason: lines.join('\n'),
    );
    expect(lines.where((line) => line.contains('secret')), isEmpty, reason: 'typed text must never be logged');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

class _RecordingOutput extends LogOutput {
  _RecordingOutput(this.lines);

  final List<String> lines;

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

class _AllFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => true;
}
