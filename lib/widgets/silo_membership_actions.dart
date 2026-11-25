import 'package:flutter/widgets.dart';

import '../media/media_item.dart';
import '../services/silo/silo_memberships.dart';
import '../utils/snackbar_helper.dart';

/// Flips [item]'s Watchlist or Favorites membership on [client] and says how
/// it went: "Added to Watchlist", or the server's reason when it refused (the
/// state has then gone back). A press queued behind a write says nothing; the
/// write that sends it does.
Future<void> toggleSiloMembership(
  BuildContext context,
  MembershipListsClient client,
  MediaItem item,
  SiloMembership kind,
) async {
  final outcome = await client.memberships.toggle(item, kind);
  if (outcome == null) return;
  final message = outcome.message;
  if (!context.mounted) {
    showMainSnackBar(message);
  } else if (outcome.ok) {
    showSuccessSnackBar(context, message);
  } else {
    showErrorSnackBar(context, message);
  }
}
