import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'; // For debugPrint, if needed

mixin VolumeButtonMixin<T extends StatefulWidget> on State<T> {
  bool _volumeKeyHandler(KeyEvent event) {
    // We only care about down or repeat events for volume adjustment
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.physicalKey == PhysicalKeyboardKey.audioVolumeUp) {
        // Your logic for volume up
        // e.g., increaseVolume();
        debugPrint('Volume Up pressed');
        return true; // Handled
      } else if (event.physicalKey == PhysicalKeyboardKey.audioVolumeDown) {
        // Your logic for volume down
        // e.g., decreaseVolume();
        debugPrint('Volume Down pressed');
        return true; // Handled
      }
      // Optionally handle mute:
      // else if (event.physicalKey == PhysicalKeyboardKey.audioVolumeMute) { ... }
    }

    return false; // Not handled by us
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_volumeKeyHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_volumeKeyHandler);
    super.dispose();
  }
}