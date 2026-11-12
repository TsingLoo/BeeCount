// 只为了能用 profile 模式跑 integration_test/s3_collaboration_e2ee_live_test.dart:
// debug 模式没有 AOT,PBKDF2 的耗时会慢一个数量级,量不出用户真实等待时间。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
