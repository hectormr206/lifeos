import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/widgets.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/domain_descriptor.dart';

/// All registered domains in one quiet navigation group. Each domain's local
/// screen works fully offline/unpaired; the registry owns icons and labels.
class DomainsHubScreen extends StatelessWidget {
  const DomainsHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Keep the destination named exactly like the home navigation row.
      appBar: AppBar(title: Text(AppLocalizations.of(context).homeMyData)),
      body: PageBody(children: [
        GroupedList(children: [
          for (final descriptor in domainDescriptors)
            GroupedRow(
              icon: descriptor.icon,
              title: descriptor.title,
              onTap: () => context.push('/domains/${descriptor.key}'),
            ),
        ]),
      ]),
    );
  }
}
