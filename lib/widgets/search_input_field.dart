import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import 'app_icon.dart';
import 'pill_input_decoration.dart';

/// The pill search field the search screens put above their results, with the
/// clear affordance that appears once there is text: RIGHT out of the field
/// lands on it, LEFT goes back, and both escape down into the results.
///
/// [onBack] stays null unless the host wants the back key — a pushed route
/// needs it for its own pop.
///
/// With [onVoiceSearch] a mic button sits right of the field and the clear
/// button moves out beside it (Silo Android #830): RIGHT walks field, mic,
/// clear, and LEFT walks back.
class SearchInputField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// Names the clear button's focus node.
  final String debugLabel;

  final TvTextInputController? tvTextInputController;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onEditingComplete;
  final VoidCallback? onBack;

  /// Starts a voice search; null hides the mic.
  final VoidCallback? onVoiceSearch;

  /// The mic's tooltip and spoken label.
  final String? voiceSearchLabel;

  const SearchInputField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.debugLabel,
    this.tvTextInputController,
    this.onNavigateLeft,
    this.onNavigateDown,
    this.onEditingComplete,
    this.onBack,
    this.onVoiceSearch,
    this.voiceSearchLabel,
  });

  @override
  State<SearchInputField> createState() => _SearchInputFieldState();
}

class _SearchInputFieldState extends State<SearchInputField> {
  late final FocusNode _clearFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.clear');
  late final FocusNode _voiceFocusNode = FocusNode(debugLabel: '${widget.debugLabel}.voice');

  @override
  void dispose() {
    _clearFocusNode.dispose();
    _voiceFocusNode.dispose();
    super.dispose();
  }

  void _clearSearch() {
    widget.controller.clear();
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.isNotEmpty;
    final onVoiceSearch = widget.onVoiceSearch;
    final field = FocusableTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      tvTextInputController: widget.tvTextInputController,
      textInputAction: TextInputAction.search,
      onNavigateLeft: widget.onNavigateLeft,
      onNavigateRight: onVoiceSearch != null
          ? _voiceFocusNode.requestFocus
          : (hasText ? _clearFocusNode.requestFocus : null),
      onNavigateDown: widget.onNavigateDown,
      onEditingComplete: widget.onEditingComplete,
      onBack: widget.onBack,
      decoration: pillInputDecoration(
        context,
        hintText: widget.hintText,
        prefixIcon: const AppIcon(Symbols.search_rounded, fill: 1),
        suffixIcon: hasText && onVoiceSearch == null ? const SizedBox(width: 48) : null,
      ),
    );
    final clear = FocusableButton(
      focusNode: _clearFocusNode,
      onPressed: _clearSearch,
      onNavigateLeft: onVoiceSearch != null ? _voiceFocusNode.requestFocus : widget.focusNode.requestFocus,
      onNavigateDown: widget.onNavigateDown,
      autoScroll: false,
      child: IconButton(icon: const AppIcon(Symbols.clear_rounded, fill: 1), onPressed: _clearSearch),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
      child: onVoiceSearch == null
          ? Stack(alignment: Alignment.centerRight, children: [field, if (hasText) clear])
          : Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 8),
                FocusableButton(
                  focusNode: _voiceFocusNode,
                  onPressed: onVoiceSearch,
                  onNavigateLeft: widget.focusNode.requestFocus,
                  onNavigateRight: hasText ? _clearFocusNode.requestFocus : null,
                  onNavigateDown: widget.onNavigateDown,
                  autoScroll: false,
                  child: IconButton(
                    tooltip: widget.voiceSearchLabel,
                    icon: const AppIcon(Symbols.mic_rounded, fill: 1),
                    onPressed: onVoiceSearch,
                  ),
                ),
                if (hasText) clear,
              ],
            ),
    );
  }
}
