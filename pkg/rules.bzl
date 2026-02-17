load("@aspect_bazel_lib//lib:glob_match.bzl", "glob_match")
load("@bazel_util//util:path.bzl", "runfile_path")
load("@rules_pkg//pkg:providers.bzl", "PackageDirsInfo", "PackageFilegroupInfo", "PackageFilesInfo", "PackageSymlinkInfo")

def _runfiles_symlinks(workspace_name, runfiles):
    files = {}
    for file in runfiles.files.to_list():
        files[runfile_path(workspace_name, file)] = file
    for file in runfiles.symlinks.to_list():
        files[file.path] = "%s/%s" % (workspace_name, file.target_file)
    for file in runfiles.root_symlinks.to_list():
        files[file.path] = file.target_file
    return files

def _pkg_executable_impl(ctx):
    bin = ctx.executable.bin
    bin_default = ctx.attr.bin[DefaultInfo]
    path = ctx.attr.path
    label = ctx.label
    workspace_name = ctx.workspace_name

    runfiles_symlinks = _runfiles_symlinks(workspace_name, bin_default.default_runfiles)
    pkg_files = PackageFilesInfo(
        dest_src_map = {"%s.files/%s" % (path, file.path): file for file in [bin] + runfiles_symlinks.values()},
        attributes = {"mode": "0755"},
    )
    pkg_metadata = PackageFilesInfo(
        dest_src_map = {"%s.runfiles/_repo_mapping" % path: bin_default.files_to_run.repo_mapping_manifest},
        attributes = {"mode": "0644"},
    )
    pkg_symlinks = [
        PackageSymlinkInfo(
            attributes = {"mode": "0755"},
            destination = "%s.runfiles/%s" % (path, p),
            target = "%s/%s.files/%s" % ("/".join([".." for part in p.split("/")]), path, file.path),
        )
        for p, file in runfiles_symlinks.items()
    ]

    pkg_symlinks.append(
        PackageSymlinkInfo(
            attributes = {"mode": "0755"},
            destination = path,
            target = "%s.files/%s" % (path, bin.path),
        ),
    )

    pkg_filegroup_info = PackageFilegroupInfo(
        pkg_files = [(pkg_files, label), (pkg_metadata, label)],
        pkg_symlinks = [(symlink_info, label) for symlink_info in pkg_symlinks],
    )

    default_info = DefaultInfo(
        files = depset([bin, bin_default.files_to_run.repo_mapping_manifest] + runfiles_symlinks.values()),
    )

    return [default_info, pkg_filegroup_info]

pkg_executable = rule(
    implementation = _pkg_executable_impl,
    attrs = {
        "bin": attr.label(
            doc = "Executable.",
            executable = True,
            cfg = "target",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Packaged path of executable. (Runfiles tree will be at <path>.runfiles.)",
            mandatory = True,
        ),
    },
    provides = [PackageFilegroupInfo],
)

def _pattern_negate(pattern):
    return pattern[1:] if pattern.startswith("!") else "!" + pattern

def _patterns_match(patterns, value):
    for pattern in patterns:
        if pattern.startswith("!"):
            if glob_match(expr = pattern[1:], path = value):
                return False
        elif glob_match(expr = pattern, path = value):
            return True
    return False

def _filter_dirs_info(dirs_info, patterns):
    return PackageDirsInfo(
        attributes = getattr(dirs_info, "attributes", {}),
        dirs = [path for path in dirs_info.dirs if _patterns_match(patterns, path)],
    )

def _filter_files_info(files_info, patterns):
    return PackageFilesInfo(
        attributes = getattr(files_info, "attributes", {}),
        dest_src_map = {dest: src for dest, src in files_info.dest_src_map.items() if _patterns_match(patterns, dest)},
    )

def _pkg_filter_impl(ctx):
    patterns = ctx.attr.patterns
    src_pkg = ctx.attr.src[PackageFilegroupInfo]

    srcs = []

    pkg_files = []
    for files_info, origin in getattr(src_pkg, "pkg_files", []):
        files_info = _filter_files_info(files_info, patterns)
        if files_info.dest_src_map:
            pkg_files.append((files_info, origin))
            for src in files_info.dest_src_map.values():
                srcs.append(src)

    pkg_dirs = []
    for dirs_info, origin in getattr(src_pkg, "pkg_dirs", []):
        dirs_info = _filter_dirs_info(dirs_info, patterns)
        if dirs_info.directories:
            pkg_dirs.append((pkg_dirs, origin))

    pkg_symlinks = [
        (symlink, origin)
        for symlink, origin in getattr(src_pkg, "pkg_symlinks", [])
        if _patterns_match(patterns, symlink.destination)
    ]

    pkg_filegroup_info = PackageFilegroupInfo(
        pkg_files = pkg_files,
        pkg_dirs = pkg_dirs,
        pkg_symlinks = pkg_symlinks,
    )

    default_info = DefaultInfo(files = depset(srcs))

    return [default_info, pkg_filegroup_info]

pkg_filter = rule(
    implementation = _pkg_filter_impl,
    attrs = {
        "patterns": attr.string_list(),
        "src": attr.label(providers = [PackageFilegroupInfo]),
    },
    provides = [PackageFilegroupInfo],
)

def pkg_split(name, src, patterns, package_dir = None, **kwargs):
    previous = []
    for index, (pattern_name, patterns) in enumerate(patterns.items()):
        pkg_filter(
            name = "%s.%s" % (name, pattern_name),
            src = src,
            patterns = previous + patterns,
            **kwargs
        )
        for pattern in patterns:
            previous.append(_pattern_negate(pattern))
