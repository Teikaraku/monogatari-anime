import 'dart:async';
import 'dart:math';

import 'package:dtorrent_task_v2/src/peer/peer_base.dart';
import 'package:dtorrent_task_v2/src/peer/protocol/peer_events.dart';
import 'package:events_emitter2/events_emitter2.dart';

import '../utils.dart';

/// 500 ms
const ccontrolTarget = 1000000;

const maxWindow = 1048576;

const recordTime = 5000000;

/// The maximum number of requests to be increased in each round is 3.
const maxCwndIncreaseRequestsPerRtt = 3 * 16384;

/// Initial congestion window size for uTP (optimized for better performance)
/// Set to 2.5x defaultRequestLength (40960 bytes) for faster startup
const initialUtpCwnd = 40960; // defaultRequestLength * 2.5 = 16384 * 2.5

/// LEDBAT Congestion Control
///
/// Note: All time units are in microseconds
mixin CongestionControl on EventsEmittable<PeerEvent> {
  // The initial value is 10 seconds.
  double _rto = 10000000;

  double? _srtt;

  double? _rttvar;

  Timer? _timeout;

  int _allowWindowSize = defaultRequestLength;

  /// Playback must not reserve a needed block on a silent peer indefinitely.
  /// Normal downloads retain the original adaptive retry budget.
  Duration? requestDeadline;
  int minimumRequestWindow = 1;

  final List<List<dynamic>> _downloadedHistory = <List<dynamic>>[];

  /// Initialize congestion window for uTP peers with optimized initial value
  void initializeUtpCwnd() {
    _allowWindowSize = initialUtpCwnd;
  }

  /// Update the timeout.
  void updateRTO(int rtt) {
    if (rtt == 0) return;
    if (_srtt == null) {
      _srtt = rtt.toDouble();
      _rttvar = rtt / 2;
    } else {
      _rttvar = (1 - 0.25) * _rttvar! + 0.25 * (_srtt! - rtt).abs();
      _srtt = (1 - 0.125) * _srtt! + 0.125 * rtt;
    }
    _rto = _srtt! + max(100000, 4 * _rttvar!);
    // If less than 1 second, set it to 1 second.
    _rto = max(_rto, 1000000);
  }

  List<List<int>> get currentRequestBuffer;

  void timeOutErrorHappen();

  void orderResendRequest(int index, int begin, int length, int resend);

  void startRequestDataTimeout([int times = 0]) {
    _timeout?.cancel();
    var requests = currentRequestBuffer;
    if (requests.isEmpty) return;
    final budget =
        min(_rto.toInt(), requestDeadline?.inMicroseconds ?? _rto.toInt());
    final age = DateTime.now().microsecondsSinceEpoch - requests.first[3];
    // Adding another request must not extend the oldest request's deadline.
    _timeout = Timer(Duration(microseconds: max(0, budget - age)), () {
      if (requests.isEmpty) return;
      var now = DateTime.now().microsecondsSinceEpoch;
      var first = requests.first;
      var timeoutR = <List<int>>[];
      while ((now - first[3]) >= budget) {
        var request = requests.removeAt(0);
        timeoutR.add(request);
        if (requests.isEmpty) break;
        first = requests.first;
      }
      // Timers may wake slightly early; that is not another failed attempt.
      if (timeoutR.isEmpty) {
        startRequestDataTimeout(times);
        return;
      }
      if (times + 1 >= 5) {
        requests.insertAll(0, timeoutR);
        timeOutErrorHappen();
        return;
      }
      for (var request in timeoutR) {
        orderResendRequest(request[0], request[1], request[2], request[4]);
      }

      times++;
      _rto *= 2;
      _allowWindowSize = defaultRequestLength;
      //TODO: remove the need for casting
      events.emit(RequestTimeoutEvent(timeoutR, this as Peer));
      startRequestDataTimeout(times);
    });
  }

  void ackRequest(List<List<int>> requests) {
    if (requests.isEmpty) return;
    var downloaded = 0;
    int? minRtt;
    for (var request in requests) {
      // Ignore the received packets after resending.
      if (request[4] != 0) continue;
      var now = DateTime.now().microsecondsSinceEpoch;
      var rtt = now - request[3];
      minRtt ??= rtt;
      minRtt = min(minRtt, rtt);
      updateRTO(rtt);
      downloaded += request[2];
    }
    if (downloaded == 0 || minRtt == null) return;
    var artt = minRtt;
    var delayFactor = (ccontrolTarget - artt) / ccontrolTarget;
    var windowFactor = downloaded / _allowWindowSize;
    var scaledGain = maxCwndIncreaseRequestsPerRtt * delayFactor * windowFactor;

    _allowWindowSize += scaledGain.toInt();
    _allowWindowSize = max(defaultRequestLength, _allowWindowSize);
    _allowWindowSize = min(maxWindow, _allowWindowSize);
  }

  int get currentWindow {
    var c = _allowWindowSize ~/ defaultRequestLength;
    // var cw = 2 + (currentSpeed * 500 / defaultRequestLength).ceil();
    // print('$cw, $c');
    return max(minimumRequestWindow, c);
  }

  void clearCC() {
    _timeout?.cancel();
    _downloadedHistory.clear();
  }
}
