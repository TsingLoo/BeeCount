import 'dart:async';

import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/cloud/cloud_service_page.dart';
import 'package:beecount/providers/sync_providers.dart';
import 'package:beecount/widgets/ui/capsule_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('cloud page waits for active S3 collaboration before showing a tab',
      (tester) async {
    SharedPreferences.setMockInitialValues({'multi_device_sync': false});
    final active = Completer<CloudServiceConfig>();
    final collaboration = CloudServiceConfig(
      type: CloudBackendType.s3Collaboration,
      name: 'S3 collaboration',
      s3Endpoint: 'example.test',
      s3AccessKey: 'key',
      s3SecretKey: 'secret',
      s3Bucket: 'bucket',
      s3SyncPassword: 'test password',
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        activeCloudConfigProvider.overrideWith((ref) => active.future),
        beecountCloudConfigProvider.overrideWith((ref) async => null),
        supabaseConfigProvider.overrideWith((ref) async => null),
        webdavConfigProvider.overrideWith((ref) async => null),
        s3ConfigProvider.overrideWith((ref) async => null),
        s3CollaborationConfigProvider
            .overrideWith((ref) async => collaboration),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CloudServicePage(),
      ),
    ));

    expect(find.byType(CapsuleSwitcher<String>), findsNothing);
    active.complete(collaboration);
    await tester.pumpAndSettle();

    expect(tester.widget<CapsuleSwitcher<String>>(
      find.byType(CapsuleSwitcher<String>)).selectedValue, 'cloud');
    expect(find.text('未测试'), findsNothing);
    expect(find.text('S3 云端协同'), findsWidgets);
  });
}
