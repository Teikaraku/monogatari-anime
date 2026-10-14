# Vendored dtorrent_task_v2

Source: https://pub.dev/packages/dtorrent_task_v2/versions/0.5.4
Repository: https://github.com/atlet99/dtorrent_task_v2
Version: 0.5.4
Published archive SHA-256: 890125d51478805988db1a62b21c87c87d7ae633aea6fd32db0d8acfa8e38ebe
License: BSD 3-Clause; see LICENSE. Original copyright notices are retained.

Local changes:
- Reject non-positive or greater than 16 MiB BEP 9 metadata sizes before allocating the metadata buffer.
- Avoid automatic third-party IPify lookups; tracker/peer responses still supply external endpoints.
- Do not announce metadata sessions after a cancelled DHT bootstrap completes.
- Extract the exact bencoded info dictionary with a bounded token walker, skipping binary strings; the upstream byte-counting implementation produced incorrect SHA-1 swarm identities.
- Expose the existing requestPieces method so a seek can wake peers after all previous-window requests finish.
- Deduplicate concurrent file descriptor opens and wait for active IO before closing; the upstream race leaked Windows handles and prevented cache deletion after playback.
- Apply the same descriptor deduplication and submitted-write draining to StateFileV2; concurrent piece completions could leak the resume-state file handle, and closing the stream before queued writes completed could strand their futures.
- Allow disabling the redundant global metadata cache; Monogatari persists metadata with its task records instead.
- Export the existing file IO events so disk-write failures can be reported immediately instead of timing out as a missing peer.
- Allow disabling LSD multicast and UPnP/NAT-PMP router discovery; Monogatari disables both on all platforms, including iOS without restricted multicast entitlements.
- Start the scheduler paused before announcing trackers, so only explicitly selected files or requested playback windows are downloaded.
- Configure an optional loopback peer allowance before tracker responses arrive; only the standalone real-peer tests enable this option.
- Bootstrap DHT in the background so DNS delays cannot block working trackers; guard late socket/bootstrap completions after stop and await in-progress file initialization before releasing resources.
- Encode DHT transaction IDs and info-hashes as bencoded byte strings and decode response kinds from bytes; the original codec mismatch rejected valid public DHT responses.
- Follow DHT referrals by XOR distance with bounded parallel lookup, per-query expiry and periodic rediscovery; validate reply endpoints and transaction IDs, bound the node table, and cancel discovery timers on stop.
- Bound HTTP tracker connection/response time and payload size, reject unsuccessful status codes, and preserve original tracker query parameters.
- For streaming, keep a bounded TCP request pipeline and return silent-peer blocks to other peers after six seconds; adding new requests no longer resets the oldest block's timeout.
- Identify peers by IP, port and transport; peers sharing a NAT address previously disappeared from active scheduling and could not receive reassigned blocks.
- Hedge only stalled blocks of the currently requested playback pieces to one additional peer; cancel the slower copy and accept legitimate late responses after cancellation (BEP 6).
- Limit streaming peer connection attempts to eight seconds rather than holding unreachable endpoints for thirty seconds.

The application uses its own loopback HTTP Range server, cancellation and task
persistence. It does not use the upstream single-reader streaming interface.
The application explicitly flushes payload data on pause/stop and computes
selected-file progress rather than using upstream's single-file progress getter.
- Enforce an upload rate limit (`TorrentTask.setUploadRateLimit`): a token bucket drops peer requests beyond the cap, and a zero cap keeps peers choked. Upstream only stored scheduler upload caps without applying them.
