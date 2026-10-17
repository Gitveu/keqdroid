import 'package:flutter/widgets.dart';

// TextField отдаёт текст только по Enter, а на телефоне клавиатуру закрывают кнопкой назад: введённое пропадало молча.
// В dispose не сохраняем: уход с экрана (routes.dart, canRequestFocus) и смена вкладки (ExcludeFocus) снимают фокус раньше, а save из dispose перерисовывает запертое дерево
class CommitOnBlur extends StatefulWidget {
  const CommitOnBlur({
    super.key,
    required this.controller,
    required this.onCommit,
    required this.builder,
  });

  final TextEditingController controller;
  final ValueChanged<String> onCommit;
  final Widget Function(FocusNode focus, VoidCallback commit) builder;

  @override
  State<CommitOnBlur> createState() => _CommitOnBlurState();
}

class _CommitOnBlurState extends State<CommitOnBlur> {
  final _focus = FocusNode();
  late String _committed;

  @override
  void initState() {
    super.initState();
    _committed = widget.controller.text;
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  // Enter шлёт и onEditingComplete, и onSubmitted
  void _commit() {
    final text = widget.controller.text;
    if (text == _committed) return;
    _committed = text;
    widget.onCommit(text);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_focus, _commit);
}
