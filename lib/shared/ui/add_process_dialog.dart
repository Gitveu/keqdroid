import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../platform/platform_bootstrap.dart';
import '../../services/file_dialog_service.dart';
import '../../utils/bidi.dart';
import '../../utils/error_messages.dart';
import 'app_theme.dart';

/// «Добавить приложение» на ПК: имя процесса или путь к файлу, с выбором
/// файла. Общий у сплита и у шторки «Кто» маршрута: программа, которая сейчас
/// не запущена, в списке процессов отсутствует, и иначе её не выбрать.
///
/// Возвращает введённое как есть — выбранный файл важнее текста поля; null —
/// отмена. Проверку имени делает вызывающий: у него своё сообщение об ошибке.
Future<String?> showAddProcessDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final ctrl = TextEditingController();
  var pickedPath = '';

  // Почему не открылся выбор файла — прямо в диалоге: снекбар Scaffold
  // рисует под ним, и объяснение осталось бы за модальным барьером.
  String? pickError;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      // Заливка и форма — из `dialogTheme`: локальный `backgroundColor`
      // повторял тот же `surfaceContainerHigh`, но мимо темы, и в flair-темах
      // диалог не получал их усиленных скруглений.
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text(l10n.splitAddAppTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              textDirection: technicalInputDirection,
              decoration: InputDecoration(
                hintText: Platform.isLinux
                    ? l10n.splitAddAppHintLinux
                    : l10n.splitAddAppHint,
              ),
              autofocus: true,
            ),
            if (PlatformBootstrap.isDesktop) ...[
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () async {
                    try {
                      // У программ Linux расширения нет, и фильтр по
                      // `.exe` не дал бы выбрать ни одну.
                      final r = await AppFileDialogs.pickFile(
                        dialogTitle: l10n.splitAddAppPickFile,
                        type: Platform.isLinux ? FileType.any : FileType.custom,
                        allowedExtensions: Platform.isLinux
                            ? null
                            : const ['exe'],
                      );
                      if (r?.path != null) {
                        pickedPath = r!.path!;
                        ctrl.text = pickedPath;
                      }
                    } catch (e) {
                      // Путь всё ещё можно вписать руками в поле выше —
                      // поэтому только объясняем, а диалог не закрываем.
                      setDialogState(
                        () => pickError = friendlyErrorDetailed(e, ctx),
                      );
                    }
                  },
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: Text(l10n.splitAddAppPickFile),
                ),
              ),
              if (pickError != null) ...[
                const SizedBox(height: 8),
                Text(
                  pickError!,
                  style: Theme.of(
                    ctx,
                  ).textTheme.bodySmall?.copyWith(color: AppTheme.red(ctx)),
                ),
              ],
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.splitAddApp),
          ),
        ],
      ),
    ),
  );

  if (ok != true) return null;
  return pickedPath.isNotEmpty ? pickedPath : ctrl.text;
}
