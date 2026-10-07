"""This file provides all user facing functions.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_shell//shell:sh_binary_info.bzl", "ShBinaryInfo")
load("@rules_shell//shell:sh_info.bzl", "ShInfo")
load(":toolchain.bzl", "TOOLCHAIN_TYPE", "rlocationpath")

_SHELL_CONTENT = """\
#!/bin/sh

set -eu

{shellcheck} {args}
"""

def _batch_content(ctx, toolchain, opts, files, target_srcs, expect_fail):
    """Render the Windows test script.

    Runfiles are usually only available as a manifest on Windows, so every
    file is resolved to an absolute path with `runfiles.bat` from `rules_batch`.

    Args:
        ctx (ctx): The rule's context object.
        toolchain (ToolchainInfo): The resolved shellcheck toolchain.
        opts (list[str]): Leading `shellcheck` options.
        files (list[File]): All files to lint.
        target_srcs (list[File]): The subset of `files` collected from `targets`.
        expect_fail (bool): Whether `shellcheck` is expected to fail.

    Returns:
        str: The script content.
    """
    runfiles_bat = rlocationpath(ctx.file._runfiles_bat, ctx.workspace_name)
    lines = [
        "@ECHO OFF",
        # Locate runfiles.bat in the runfiles tree, or in the manifest if there is no tree.
        'set "RLOCATION=%RUNFILES_DIR%\\{}"'.format(runfiles_bat.replace("/", "\\")),
        'if not exist "%RLOCATION%" if defined RUNFILES_MANIFEST_FILE for /F "usebackq tokens=1,*" %%i in (`findstr /b /l /c:"{} " "%RUNFILES_MANIFEST_FILE%"`) do set "RLOCATION=%%j"'.format(runfiles_bat),
        'if not exist "%RLOCATION%" (echo>&2 ERROR: cannot find {} in runfiles & exit /b 1)'.format(runfiles_bat),
        'set "RLOCATION=%RLOCATION:/=\\%"',
    ]

    # FILE_0 is shellcheck, FILE_1 the rc file and the rest are `files`.
    for i, file in enumerate([toolchain.shellcheck, toolchain.shellcheckrc] + files):
        lines.append('call "%RLOCATION%" "{}" FILE_{} || exit /b 1'.format(rlocationpath(file, ctx.workspace_name), i))

    # Directories are not listed in the manifest, so each `--source-path` is
    # the directory of one resolved source from it. `%~dp` ends with a
    # backslash, which would escape the closing quote; append `.` to avoid that.
    dirs = {}
    for i, src in enumerate(target_srcs):
        dirs.setdefault(src.short_path.rpartition("/")[0], len(ctx.files.data) + i + 2)
    for i, file_index in enumerate(dirs.values()):
        lines.append('for %%F in ("%FILE_{}%") do set "DIR_{}=%%~dpF."'.format(file_index, i))

    args = opts + ['--rcfile="%FILE_1%"']
    args.extend(['--source-path="%DIR_{}%"'.format(i) for i in range(len(dirs))])
    args.extend(['"%FILE_{}%"'.format(i + 2) for i in range(len(files))])
    lines.append('"%FILE_0%" {}'.format(" ".join(args)))
    lines.append("if errorlevel 1 exit /b 0\r\nexit /b 1" if expect_fail else "exit /b %ERRORLEVEL%")

    # Batch files must use CRLF line endings.
    return "\r\n".join(lines) + "\r\n"

def shellcheck_test_impl(ctx, expect_fail = False):
    """The implementation of the `shellcheck_test` rule.

    Args:
        ctx (ctx): The rule's context object.
        expect_fail (bool, optional): Whether or not shellcheck is expected to fail.

    Returns:
        list: All providers.
    """
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )

    toolchain = ctx.toolchains[TOOLCHAIN_TYPE]
    executable = ctx.actions.declare_file("{}{}".format(
        ctx.label.name,
        ".bat" if is_windows else ".sh",
    ))
    runfiles = [toolchain.shellcheck, toolchain.shellcheckrc]

    cmd = []
    if ctx.attr.format:
        cmd.append("--format={}".format(ctx.attr.format))
    if ctx.attr.severity:
        cmd.append("--severity={}".format(ctx.attr.severity))

    check_generated = ctx.attr.check_generated == 1 or (
        ctx.attr.check_generated == -1 and ctx.attr._check_generated[BuildSettingInfo].value
    )
    target_srcs = [
        src
        for src in depset(transitive = [
            srcs
            for target in ctx.attr.targets
            for srcs in (target[ShellcheckSrcsInfo].srcs, target[ShellcheckSrcsInfo].transitive_srcs)
        ]).to_list()
        if src.is_source or check_generated
    ]
    files = ctx.files.data + target_srcs
    runfiles.extend(files)

    if is_windows:
        content = _batch_content(ctx, toolchain, cmd, files, target_srcs, expect_fail)
        runfiles.append(ctx.file._runfiles_bat)
    else:
        # Linting runs from the runfiles tree, so `--source-path` is derived from
        # `short_path` rather than the exec root paths in `ShellcheckSrcsInfo`.
        source_paths = depset([src.short_path.rpartition("/")[0] or "." for src in target_srcs]).to_list()

        cmd.append("--rcfile={}".format(toolchain.shellcheckrc.short_path))
        cmd.extend(["--source-path={}".format(path) for path in source_paths])
        cmd.extend([f.short_path for f in files])

        if expect_fail:
            cmd.append("|| exit 0; exit 1")

        content = _SHELL_CONTENT.format(
            shellcheck = toolchain.shellcheck.short_path,
            args = " ".join(cmd),
        )

    ctx.actions.write(
        output = executable,
        content = content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles(
                files = runfiles,
                transitive_files = toolchain.all_files,
            ),
        ),
    ]

ShellcheckSrcsInfo = provider(
    doc = "A provider containing relevant data for linting.",
    fields = {
        "source_paths": "depset[str]: `--source-path` target paths.",
        "srcs": "depset[File]: Sources collected from the target.",
        "transitive_source_paths": "depset[str]: Transitive source paths collected from dependencies.",
        "transitive_srcs": "depset[File]: Transitive sources collected from dependencies.",
    },
)

def _shellcheck_srcs_aspect_impl(_target, ctx):
    srcs = getattr(ctx.rule.files, "srcs", [])
    source_paths = [src.dirname for src in srcs]

    transitive_srcs = []
    transitive_source_paths = []

    for dep in getattr(ctx.rule.attr, "deps", []):
        if ShellcheckSrcsInfo in dep:
            transitive_srcs.extend([
                dep[ShellcheckSrcsInfo].srcs,
                dep[ShellcheckSrcsInfo].transitive_srcs,
            ])
            transitive_source_paths.extend([
                dep[ShellcheckSrcsInfo].source_paths,
                dep[ShellcheckSrcsInfo].transitive_source_paths,
            ])

    return [ShellcheckSrcsInfo(
        srcs = depset(srcs),
        source_paths = depset(source_paths),
        transitive_srcs = depset(transitive = transitive_srcs),
        transitive_source_paths = depset(transitive = transitive_source_paths),
    )]

_shellcheck_srcs_aspect = aspect(
    doc = "An aspect for collecting data about how to lint the target.",
    attr_aspects = ["deps"],
    implementation = _shellcheck_srcs_aspect_impl,
)

ATTRS = {
    "check_generated": attr.int(
        doc = (
            "Whether to lint generated files collected from `targets`: `0` never, " +
            "`1` always, `-1` defer to `//shellcheck/settings:check_generated`."
        ),
        default = -1,
        values = [-1, 0, 1],
    ),
    "data": attr.label_list(
        allow_files = True,
    ),
    "format": attr.string(
        values = ["checkstyle", "diff", "gcc", "json", "json1", "quiet", "tty"],
        doc = "The format of the outputted lint results.",
    ),
    "severity": attr.string(
        values = ["error", "info", "style", "warning"],
        doc = "The severity of the lint results.",
    ),
    "targets": attr.label_list(
        doc = "`rules_shell` targets whose sources, and those of their transitive `deps`, are linted.",
        providers = [[ShInfo], [ShBinaryInfo]],
        aspects = [_shellcheck_srcs_aspect],
    ),
    "_check_generated": attr.label(
        default = Label("//shellcheck/settings:check_generated"),
    ),
    "_runfiles_bat": attr.label(
        default = Label("@rules_batch//batch/runfiles:runfiles.bat"),
        allow_single_file = True,
    ),
    "_windows_constraint": attr.label(
        default = Label("@platforms//os:windows"),
    ),
}

shellcheck_test = rule(
    implementation = shellcheck_test_impl,
    attrs = ATTRS,
    test = True,
    toolchains = [TOOLCHAIN_TYPE],
)

def _shellcheck_aspect_impl(target, ctx):
    if target.label.workspace_root.startswith("external"):
        return []

    ignore_tags = [
        "no_shellcheck",
        "no_lint",
        "nolint",
        "noshellcheck",
    ]
    for tag in ctx.rule.attr.tags:
        if tag.replace("-", "_").lower() in ignore_tags:
            return []

    if ShellcheckSrcsInfo not in target:
        return []

    src_info = target[ShellcheckSrcsInfo]

    check_generated = ctx.attr._check_generated[BuildSettingInfo].value
    srcs = [
        src
        for src in src_info.srcs.to_list()
        if src.is_source or check_generated
    ]

    if not srcs:
        return []

    toolchain = ctx.toolchains[TOOLCHAIN_TYPE]

    inputs_direct = [toolchain.shellcheckrc] + getattr(ctx.rule.files, "data", [])
    inputs_transitive = [src_info.srcs, src_info.transitive_srcs]

    if DefaultInfo in target:
        inputs_transitive.extend([
            target[DefaultInfo].files,
            target[DefaultInfo].default_runfiles.files,
        ])

    format = ctx.attr._format[BuildSettingInfo].value
    severity = ctx.attr._severity[BuildSettingInfo].value

    output = ctx.actions.declare_file("{}.shellcheck.ok".format(target.label.name))

    tools = depset([toolchain.shellcheck], transitive = [toolchain.all_files])

    args = ctx.actions.args()
    args.add(output)
    args.add("--")
    args.add(toolchain.shellcheck)
    args.add(toolchain.shellcheckrc, format = "--rcfile=%s")
    args.add_all(src_info.source_paths, format_each = "--source-path=%s")

    if format:
        args.add(format, format = "--format=%s")

    if severity:
        args.add(severity, format = "--severity=%s")

    args.add_all(srcs)

    ctx.actions.run(
        mnemonic = "Shellcheck",
        progress_message = "Shellcheck {}".format(target.label),
        executable = ctx.file._runner,
        inputs = depset(inputs_direct, transitive = inputs_transitive),
        arguments = [args],
        env = ctx.configuration.default_shell_env,
        tools = tools,
        outputs = [output],
        execution_requirements = {"supports-path-mapping": ""},
        toolchain = TOOLCHAIN_TYPE,
    )

    return [
        OutputGroupInfo(
            shellcheck_checks = depset([output]),
        ),
    ]

shellcheck_aspect = aspect(
    doc = "An aspect for performing shellcheck checks on `rules_shell` rules.",
    implementation = _shellcheck_aspect_impl,
    attrs = {
        "_check_generated": attr.label(
            default = Label("//shellcheck/settings:check_generated"),
        ),
        "_format": attr.label(
            default = Label("//shellcheck/settings:format"),
        ),
        "_runner": attr.label(
            allow_single_file = True,
            default = Label("//shellcheck/internal:aspect_runner"),
        ),
        "_severity": attr.label(
            default = Label("//shellcheck/settings:severity"),
        ),
    },
    toolchains = [TOOLCHAIN_TYPE],
    requires = [_shellcheck_srcs_aspect],
    required_providers = [[ShInfo], [ShBinaryInfo]],
)
