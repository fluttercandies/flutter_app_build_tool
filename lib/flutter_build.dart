import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:args/args.dart';
import 'package:built_collection/built_collection.dart';
import 'package:collection/collection.dart';
import 'package:code_builder/code_builder.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_style/dart_style.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:process_run/process_run.dart';
import 'package:process_run/shell.dart';
import 'package:yaml/yaml.dart';

Future<void> tryBuild(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('project')
    ..addOption('path')
    ..addOption('env')
    ..addOption('env-path', defaultsTo: 'lib/constants/env.dart')
    ..addOption('release-config-path', defaultsTo: 'lib/constants/release.dart')
    ..addFlag('sealed')
    ..addMultiOption(
      'dist',
      allowed: BuildDist.values.map((e) => e.name).toList(),
    );
  final result = parser.parse(args);
  if (args.isEmpty || result['help'] == true) {
    print(parser.usage);
    return;
  }

  if (result['path'] == null &&
      result['project'] == null &&
      !File('${path.current}/pubspec.yaml').existsSync()) {
    throw StateError('Project or path must be provided.');
  }
  final String projectPath;
  if (result['path'] != null) {
    projectPath = '${path.current}/${result['path']}';
  } else if (result['project'] != null) {
    projectPath = '${path.current}/../${result['project']}';
  } else {
    projectPath = path.current;
  }

  final env = result['env'] as String?;
  if (env?.isNotEmpty != true) {
    throw ArgumentError('env must be specified.', 'env');
  }
  final envPath = result['env-path'];
  final releaseConfigPath = result['release-config-path'];
  final sealed = result['sealed'];
  final dist = (result['dist'] as List)
      .map((e) => BuildDist.values.firstWhere((t) => t.name == e));
  if (dist.isEmpty) {
    throw StateError('No dist has been specified.');
  }
  final workingDirectory = Uri.directory(projectPath).toFilePath();
  for (final d in dist) {
    if (!Directory(path.join(workingDirectory, d.platform)).existsSync()) {
      throw StateError(
        'Dist [${d.file}] requires '
        '[${d.platform}] platform but not exists.',
      );
    }
  }

  final shell = Shell(
    workingDirectory: workingDirectory,
    environment: _expandoEnvironment(),
  );
  await shell.run('flutter pub get');
  final envFile = File(path.join(workingDirectory, envPath));
  if (!envFile.existsSync()) {
    envFile.createSync(recursive: true);
  }
  await shell.run('env2dart -a $env -o ${envFile.path}');
  final yaml = loadYaml(
    File(path.join(workingDirectory, 'pubspec.yaml')).readAsStringSync(),
  );
  final appName = yaml['name'];
  final version = yaml['version'].toString().split('+');
  final versionName = version[0];
  if (version.elementAtOrNull(1) == null) {
    print('No version code has been set, fallback to 1.');
  }
  final versionCode = version.elementAtOrNull(1) ?? '1';
  final gitRef = await genCommitRef(shell);
  final buildTime = DateTime.now();
  final distPath = Directory(
    path.join(
      path.current,
      'dist',
      DateFormat('yyyy-MM-dd').format(buildTime),
      DateFormat('HHmmss').format(buildTime),
    ),
  )..createSync(recursive: true);
  final isSingleDist = dist.length == 1;
  for (final d in dist) {
    final releaseFile = File(path.join(workingDirectory, releaseConfigPath))
      ..createSync(recursive: true);
    final fields = [
      buildField(name: 'appName', value: appName),
      buildField(name: 'versionName', value: versionName),
      buildField(name: 'versionCode', value: versionCode, type: 'int'),
      buildField(name: 'env', value: env),
      buildField(name: 'sealed', value: sealed, type: 'bool'),
      if (gitRef != null) buildField(name: 'commitRef', value: gitRef),
      buildField(name: 'buildTime', value: buildTime.toUtc().toIso8601String()),
    ];
    final code = genReleaseCode(fields: fields);
    releaseFile.writeAsStringSync(code);
    final dist = Directory(path.join(distPath.path, d.name))
      ..createSync(recursive: true);
    final filenamePrefix = [
      if (sealed) 'SEALED',
      env,
      appName,
      '$versionName+$versionCode',
      DateFormat('yyyyMMddHHmmss').format(buildTime),
      if (gitRef != null) gitRef,
    ].join('_');
    final Map<String, Object> metadata;
    switch (d) {
      case BuildDist.apk:
        await shell.run('flutter build apk --release');
        final distName = '$filenamePrefix.apk';
        final distFilePath = path.join(dist.path, distName);
        final built = File(
          path.join(
            workingDirectory,
            'build',
            'app',
            'outputs',
            'flutter-apk',
            'app-release.apk',
          ),
        )..copySync(distFilePath);
        metadata = {
          'versionName': versionName,
          'versionCode': int.parse(versionCode),
          'filename': distName,
          'fileSize': built.lengthSync(),
          'sha256': (await sha256.bind(built.openRead()).first).toString()
        };
        break;
      case BuildDist.appbundle:
        await shell.run('flutter build appbundle --release');
        final distName = '$filenamePrefix.aab';
        final distFilePath = path.join(dist.path, distName);
        final built = File(
          path.join(
            workingDirectory,
            'build',
            'app',
            'outputs',
            'bundle',
            'release',
            'app-release.aab',
          ),
        )..copySync(distFilePath);
        metadata = {
          'versionName': versionName,
          'versionCode': int.parse(versionCode),
          'filename': distName,
          'fileSize': built.lengthSync(),
          'sha256': (await sha256.bind(built.openRead()).first).toString(),
        };
        break;
      case BuildDist.ipa:
        await shell.run(
          'flutter build ipa --release '
          '--export-options-plist=../AppStore-ExportOptions.plist',
        );
        final distName = '$filenamePrefix.ipa';
        final distFilePath = path.join(dist.path, distName);
        final bundleName = RegExp(
          r'<key>CFBundleName</key>\s+<string>(.+)</string>',
        )
            .firstMatch(
              File(
                path.join(workingDirectory, 'ios', 'Runner', 'Info.plist'),
              ).readAsStringSync(),
            )!
            .group(1)!;
        final built = File(
          path.join(
            workingDirectory,
            'build',
            'ios',
            'ipa',
            '$bundleName.ipa',
          ),
        )..copySync(distFilePath);
        metadata = {
          'versionName': versionName,
          'versionCode': int.parse(versionCode),
          'filename': distName,
          'fileSize': built.lengthSync(),
          'sha256': (await sha256.bind(built.openRead()).first).toString()
        };
        break;
    }
    copyPubspecLock(workingDirectory, dist.path);
    File(
      path.join(dist.path, '$filenamePrefix.json'),
    ).writeAsStringSync(
      jsonEncode(metadata),
    );
    await zipFiles(dist, d.file, filenamePrefix);
    if (isSingleDist) {
      openDirectory(dist.path);
    }
  }
  if (!isSingleDist) {
    openDirectory(distPath.path);
  }
  print(
    'Built locations:\n'
    '${dist.map((e) => '　—— ${Uri.directory(path.join(distPath.path, e.name)).toFilePath()}').join('\n')}',
  );
}

Field buildField({
  String type = 'String',
  required String name,
  required dynamic value,
}) {
  return Field(
    (b) => b
      ..name = name
      ..type = Reference(type)
      ..assignment =
          type == 'String' ? Code("'$value'") : Code(value.toString())
      ..static = true
      ..modifier = FieldModifier.constant,
  );
}

/// Replace recursive environment variables.
Map<String, String> _expandoEnvironment() {
  if (!Platform.isWindows) {
    return Platform.environment;
  }
  final environment = Map<String, String>.from(Platform.environment);
  final reg = RegExp(r'%(.+)%');
  String replaceVariable(String value) {
    final matches = reg.allMatches(value).map((e) => e.group(1)!);
    for (final match in matches) {
      String? variable = environment[match];
      if (variable != null) {
        final replaceKey = '%$match%';
        // Escape self referencing.
        if (!variable.contains(replaceKey) && reg.hasMatch(variable)) {
          variable = replaceVariable(variable);
        }
        value = value.replaceAll(replaceKey, variable);
      }
    }
    return value;
  }

  for (final entry in environment.entries) {
    environment[entry.key] = replaceVariable(entry.value);
  }
  return environment;
}

Future<String?> genCommitRef(Shell shell) async {
  final gitStatus =
      await shell.run('git reflog -n1').catchError((e) => <ProcessResult>[]);
  final gitRef = RegExp(r'[0-9a-zA-Z]{6,8}')
      .allMatches(gitStatus.firstOrNull?.stdout.toString() ?? '')
      .firstOrNull
      ?.group(0);
  return gitRef;
}

String genReleaseCode({
  required List<Field> fields,
  String className = 'Release',
}) {
  final clazz = Class(
    (b) => b
      ..name = className
      ..modifier = ClassModifier.final$
      ..constructors = ListBuilder([
        Constructor(
          (b) => b
            ..constant = true
            ..name = '_',
        )
      ])
      ..fields = ListBuilder(fields),
  );
  final emitter = DartEmitter.scoped();
  final code = Library(
    (b) => b
      ..body.addAll([clazz])
      ..comments = ListBuilder([
        '======================================',
        'GENERATED CODE - DO NOT MODIFY BY HAND',
        '======================================',
      ]),
  ).accept(emitter).toString();
  return DartFormatter(fixes: StyleFix.all).format(code);
}

void copyPubspecLock(String workingDirectory, String distPath) {
  File(
    path.join(workingDirectory, 'pubspec.lock'),
  ).copySync(
    path.join(distPath, 'pubspec.lock'),
  );
}

Future<void> zipFiles(
  Directory dist,
  String extension,
  String filenamePrefix,
) async {
  final encoder = ZipFileEncoder();
  final zipName = '$filenamePrefix.$extension.zip';
  encoder.create(path.join(dist.path, zipName));
  for (final file in dist.listSync()) {
    if (file.path.contains(zipName)) {
      continue;
    }
    await encoder.addFile(file as File);
  }
  encoder.close();
}

Future<void> openDirectory(String path) async {
  final shell = Shell(
    verbose: false,
    commandVerbose: false,
    commentVerbose: false,
  );
  try {
    if (Platform.isMacOS) {
      await shell.run('open $path');
    } else if (Platform.isWindows) {
      await shell.run('explorer $path');
    } else if (Platform.isLinux) {
      await shell.run('nautilus $path');
    }
  } catch (e) {
    if (e is ShellException && e.result?.exitCode == 1) {
      if (e.result?.exitCode == 1) {
        return;
      }
      final pid = e.result?.pid;
      if (pid != null) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    }
    rethrow;
  }
}

enum BuildDist {
  apk('apk', 'android'),
  appbundle('aab', 'android'),
  ipa('ipa', 'ios'),
  ;

  const BuildDist(this.file, this.platform);

  final String file;
  final String platform;
}
