load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_file//util:path.bzl", "runfile_path")

def _apt_packages_index_impl(ctx):
    actions = ctx.actions
    name = ctx.attr.name
    srcs = ctx.files.srcs
    workspace = ctx.workspace_name

    dummy = actions.declare_file("%s.dummy" % name)
    actions.write(content = "", output = dummy)
    output_dir = paths.dirname(dummy.path)

    links = []
    for src in srcs:
        link = actions.declare_file("%s.packages/pool/%s" % (name, runfile_path(workspace, src)))
        links.append(link)
        actions.symlink(output = link, target_file = src)

    index = actions.declare_file("%s.txt" % name)
    args = actions.args()
    args.add("%s/%s.packages" % (output_dir, name))
    args.add(index)
    actions.run_shell(
        arguments = [args],
        command = '(cd "$1" && dpkg-scanpackages -m pool) > "$2"',
        inputs = links,
        outputs = [index],
        use_default_shell_env = True,
    )

    output = actions.declare_file("%s.gz" % name)

    args = actions.args()
    args.add(index)
    args.add(output)
    actions.run_shell(
        arguments = [args],
        command = 'gzip -c "$1" > "$2"',
        inputs = [index],
        outputs = [output],
        use_default_shell_env = True,
    )

    default_info = DefaultInfo(files = depset([output]))

    return [default_info]

apt_packages_index = rule(
    attrs = {
        "srcs": attr.label_list(allow_files = [".deb"]),
    },
    implementation = _apt_packages_index_impl,
)

def _apt_repo_impl(ctx):
    actions = ctx.actions
    name = ctx.attr.name
    packages_index = ctx.file.packages_index
    sources_index = ctx.file.sources_index
    srcs = ctx.files.srcs
    workspace = ctx.workspace_name

    symlinks = []
    if packages_index:
        symlink = actions.declare_file("%s/Packages.gz" % name)
        actions.symlink(output = symlink, target_file = packages_index)
        symlinks.append(symlink)
    if sources_index:
        symlink = actions.declare_file("%s/Sources.gz" % name)
        actions.symlink(output = symlink, target_file = sources_index)
        symlinks.append(symlink)
    for src in srcs:
        symlink = actions.declare_file("%s/pool/%s" % (name, runfile_path(workspace, src)))
        actions.symlink(output = symlink, target_file = src)
        symlinks.append(symlink)

    default_info = DefaultInfo(files = depset(symlinks))

    return [default_info]

apt_repo_ = rule(
    attrs = {
        "packages_index": attr.label(allow_single_file = [".gz"]),
        "sources_index": attr.label(allow_single_file = [".gz"]),
        "srcs": attr.label_list(allow_files = True),
    },
    implementation = _apt_repo_impl,
)

def apt_repo(name, debs):
    apt_packages_index(
        name = "%s.packages" % name,
        srcs = debs,
    )

    apt_repo_(
        name = name,
        packages_index = "%s.packages" % name,
        srcs = debs,
    )
