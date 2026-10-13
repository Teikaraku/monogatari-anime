import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:kazumi/services/storage/storage.dart';

Future<bool> torrentNetworkAllowed() async {
  if (!GStorage.getSetting(SettingsKeys.rssWifiOnly)) return true;
  if (!Platform.isAndroid && !Platform.isIOS) return true;
  try {
    final networks = await Connectivity().checkConnectivity();
    return networks.contains(ConnectivityResult.wifi) ||
        networks.contains(ConnectivityResult.ethernet);
  } catch (_) {
    return false;
  }
}
