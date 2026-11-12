import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0;
  final requestPaths = <String>[];
  server.listen((request) async {
    requests++;
    requestPaths.add(request.uri.path);
    request.response.headers.contentType = ContentType('application', 'xml');
    if (request.uri.queryParameters['continuation-token'] == null) {
      request.response.write('''
<ListBucketResult><IsTruncated>true</IsTruncated>
<Contents><Key>first.json</Key></Contents>
<NextContinuationToken>next-page</NextContinuationToken></ListBucketResult>''');
    } else {
      request.response.write('''
<ListBucketResult><IsTruncated>false</IsTruncated>
<Contents><Key>second.json</Key></Contents></ListBucketResult>''');
    }
    await request.response.close();
  });
  final client = S3Client(
    endpoint: '127.0.0.1',
    port: server.port,
    region: 'us-east-1',
    accessKey: 'test',
    secretKey: 'test',
    useSSL: false,
  );
  final virtualClient = S3Client(
    endpoint: '127.0.0.1',
    port: server.port,
    region: 'us-east-1',
    accessKey: 'test',
    secretKey: 'test',
    useSSL: false,
    virtualHostedStyle: true,
  );
  try {
    final legacyKeys = await client.listObjects(bucket: 'bucket');
    if (requests != 1 || legacyKeys.join(',') != 'first.json') {
      throw StateError('Legacy S3 listing changed: requests=$requests keys=$legacyKeys');
    }
    final keys = await client.listObjectsAllPages(bucket: 'bucket');
    if (requests != 3 || keys.join(',') != 'first.json,second.json') {
      throw StateError('S3 pagination failed: requests=$requests keys=$keys');
    }
    await virtualClient.listObjects(bucket: 'bucket');
    await virtualClient.putObject(
        bucket: 'bucket', key: 'probe.json', data: Uint8List(0));
    if (requestPaths.join(',') !=
        '/bucket,/bucket,/bucket,/,/probe.json') {
      throw StateError('S3 URL style mismatch: $requestPaths');
    }
    stdout.writeln('Legacy listing, collaboration pagination and COS URL style OK');
  } finally {
    client.dispose();
    virtualClient.dispose();
    await server.close(force: true);
  }
}
