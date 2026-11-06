#!/usr/bin/perl
# SM1369 X0: CORE NAMES NO EXTENSION.
#
# Ruling 55 (2026-11-04) moves the Odoo elements out of core and into their
# extension, behind generic hooks (tmp/proposal-extension-hooks.md, slice X0).
# The hooks take several releases to build, and Odoo work goes on meanwhile: the
# 0.16.3 batch alone added coupling in seven rows of the proposal's inventory.
# This freezes the count while the hooks are built (risk R-5): a NEW core line
# that names an extension fails here, and the lines already there are an
# allow-list that may only shrink.
#
# CORE is every functional file that is not an extension's own: the CGIs and
# install.pl at the root, the processor's parts, the library, the tools and the
# shipped scripts (lint 240's set), plus the manager pages, the system,
# component and layout templates and the installer templates, which carry
# couplings of their own (the inventory's I-7, I-17, I-25). Not core: the
# descriptors in extensions/, the endpoints each declares in `owns.endpoints`,
# the files %OWN names (an extension's payload, which leaves with it in X7),
# the shipped docs (H-10 moves those) and the tests.
#
# NAMING AN EXTENSION, each a class rather than a list of today's offenders:
#
#   * an extension's script name - `extensions/data.pl`, `odoo.pl` - for every
#     descriptor in extensions/, read from the directory, so a new extension is
#     covered the day it lands;
#   * an extension's own name, where it is distinctive enough for a pattern to
#     tell it from prose (%NAMED). Odoo's are odoo, OOM and oomd, the measure
#     the proposal's inventory used (M-2). An id that is an ordinary word -
#     data, log, stats - cannot be told from prose by a pattern, and is covered
#     by its script name alone.
#
# Comments, POD and HTML or template comments are left out, as lint 240 leaves
# them out: prose may name the boundary it describes, code may not.
#
# THE ALLOW-LIST MAY ONLY SHRINK. Each core file that names an extension today
# carries its count of such lines. A file over its count, or a file not in the
# list, fails: that is new coupling, and it belongs behind a hook. A file UNDER
# its count fails too, until the count is lowered to match, so headroom freed by
# a hook slice cannot be spent again by the next change. X7 empties Odoo's part.
#
# Sabotage: add `my $x = 'extensions/odoo.pl';` to lib/Lazysite/Paths.pm and this
# fails naming the file and the line.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# An extension's own files, beyond its descriptor and its declared endpoints:
# the payload that leaves core with it. Odoo's is its engine, its browser
# helper, its sign-in page and component, and the warm endpoint's service.
my %OWN = (
    odoo => [
        qr{\Alib/Lazysite/Odoo\.pm\z}, qr{\Alib/Lazysite/Odoo/},
        qr{\Astarter/assets/lazysite-odoo\.js\z}, qr{\Alib/Lazysite/Daemon/Service/OdooEndpoint\.pm\z},
        qr{\Astarter/lazysite/templates/(?:components|system)/odoo-signin\.(?:tt|md)\z},
    ],
);

# An extension's own name, where a pattern can tell it from prose. A letter on
# either side is another word (room, zoom); a capital after it is a compound
# (OdooEndpoint), which names it.
my %NAMED = ( odoo => qr{(?<![A-Za-z])(?:[Oo]doo|ODOO|[Oo]om|OOM)d?(?![a-z])} );

# The allow-list: each core file's count of lines naming an extension, measured
# on 2026-11-06 at b7f178856. It may only shrink.
my %ALLOWED = (
    'install.pl'                                 => 1,
    'installers/apache/vhost-fcgi.conf.example'  => 1,
    'installers/hestia/lazysite-fcgi.stpl'       => 1,
    'installers/hestia/lazysite-fcgi.tpl'        => 1,
    'installers/nginx/vhost-fcgi.conf.example'   => 1,
    'lazysite-auth.pl'                           => 2,
    'lazysite-manager-api.pl'                    => 26,
    'lazysite-mcp.pl'                            => 39,
    'lazysite-processor.pl'                      => 8,
    'lazysite-processor/app.pm'                  => 1,
    'lazysite-processor/auth.pm'                 => 1,
    'lazysite-processor/components.pm'           => 1,
    'lazysite-processor/forms.pm'                => 1,
    'lazysite-processor/front-door.pm'           => 15,
    'lazysite-processor/layout.pm'               => 7,
    'lazysite-processor/pipeline.pm'             => 1,
    'lazysite-processor/remap.pm'                => 1,
    'lazysite-processor/render.pm'               => 15,
    'lazysite-processor/sources.pm'              => 37,
    'lib/Lazysite/Auth/AddressRefs.pm'           => 2,
    'lib/Lazysite/Auth/Identity.pm'              => 1,
    'lib/Lazysite/Auth/LoginRate.pm'             => 1,
    'lib/Lazysite/Auth/Session.pm'               => 33,
    'lib/Lazysite/Auth/Settings.pm'              => 1,
    'lib/Lazysite/Capabilities.pm'               => 9,
    'lib/Lazysite/ControlApi/Actions.pm'         => 20,
    'lib/Lazysite/Daemon/Jobs.pm'                => 1,
    'lib/Lazysite/Daemon/Service/Oomd.pm'        => 51,
    'lib/Lazysite/Daemon/Supervisor.pm'          => 23,
    'lib/Lazysite/Handlers.pm'                   => 49,
    'lib/Lazysite/Maintenance.pm'                => 1,
    'lib/Lazysite/Manager/Briefs.pm'             => 1,
    'lib/Lazysite/Manager/Common.pm'             => 5,
    'lib/Lazysite/Manager/Config.pm'             => 1,
    'lib/Lazysite/Manager/Data.pm'               => 1,
    'lib/Lazysite/Manager/PagePdf.pm'            => 1,
    'lib/Lazysite/Manager/Remap.pm'              => 1,
    'lib/Lazysite/Manager/Services.pm'           => 1,
    'lib/Lazysite/Manager/StartPage.pm'          => 2,
    'lib/Lazysite/Notify.pm'                     => 3,
    'lib/Lazysite/Outbox.pm'                     => 1,
    'lib/Lazysite/Stores.pm'                     => 1,
    'lib/Lazysite/Validate.pm'                   => 9,
    'lib/Lazysite/WarmFork.pm'                   => 9,
    'lib/Lazysite/WarmFork/Wire.pm'              => 1,
    'starter/lazysite/templates/system/login.md' => 4,
    'starter/manager/config.md'                  => 2,
    'starter/manager/extension-config.md'        => 17,
    'starter/manager/groups.md'                  => 1,
    'starter/manager/users.md'                   => 1,
    'tools/bench-surfaces.pl'                    => 69,
    'tools/bench.pl'                             => 1,
    'tools/coverage-groups.pl'                   => 1,
    'tools/ext-compat.sh'                        => 18,
    'tools/lazysite-check.pl'                    => 60,
    'tools/lazysite-server.pl'                   => 1,
    'tools/precheck-areas.pl'                    => 4,
    'tools/vendor-oom.sh'                        => 20,
);

# ---- the extensions, and what is theirs ----
opendir my $xd, "$root/extensions" or die "extensions/: $!";
my @stems = sort map { /\A([a-z][a-z0-9-]*)\.pl\z/ ? $1 : () } readdir $xd;
closedir $xd;
cmp_ok( scalar @stems, '>=', 10, 'the extensions were found (' . scalar(@stems) . ')' );

my %own_file;
for my $s (@stems) {
    open my $fh, '<', "$root/extensions/$s.pl" or die "extensions/$s.pl: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    if ( $src =~ /\bendpoints\s*=>\s*\[([^\]]*)\]/ ) {
        $own_file{$1} = 1 for $1 =~ /'([a-z][a-z0-9-]*\.pl)'/g;
    }
}
ok( $own_file{'lazysite-data.pl'}, "a declared endpoint is the extension's own (lazysite-data.pl)" );

my $SCRIPT = do {
    my $alt = join '|', map { quotemeta } @stems;
    qr{(?<![\w.-])(?:$alt)\.pl\b};
};
my @RULES = ( [ "an extension's script", $SCRIPT ],
    map { [ "the $_ extension by name", $NAMED{$_} ] } sort keys %NAMED );

# ---- the core files ----
my @files;
push @files, grep { -f } glob("$root/*.pl");
push @files, glob("$root/lazysite-processor/*.pm"), glob("$root/tools/*.pl"),
    glob("$root/tools/*.sh"), glob("$root/starter/assets/*.js"), glob("$root/starter/manager/*.md");
find( { no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f && /\.pm\z/ } }, "$root/lib" );
for my $d ( map { "$root/starter/lazysite/templates/$_" } qw(system components layouts) ) {
    find( { no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f } }, $d ) if -d $d;
}
# The installer templates and scripts; their READMEs and runbooks are docs.
find( { no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f && !/\.md\z/ } },
    "$root/installers" );

my @core;
for my $f ( sort @files ) {
    ( my $rel = $f ) =~ s{\A\Q$root\E/}{};
    next if $rel =~ m{\A(?:tmp|dist)/};
    next if $own_file{$rel};
    next if grep { $rel =~ $_ } map { @$_ } values %OWN;
    push @core, $rel;
}
cmp_ok( scalar @core, '>', 200, 'the core files were found (' . scalar(@core) . ')' );

# One file's lines that name an extension, comments and POD left out.
sub naming_lines {
    my ($rel) = @_;
    open my $fh, '<', "$root/$rel" or die "$rel: $!";
    my $perl = $rel =~ /\.(?:pl|pm|sh)\z/ || $rel =~ m{\Ainstallers/};
    my $js   = $rel =~ /\.js\z/;
    my ( $pod, $html, $n, @hits ) = ( 0, 0, 0 );
    while ( my $l = <$fh> ) {
        $n++;
        last if $rel =~ /\.p[lm]\z/ && $l =~ /\A__(?:END|DATA)__\b/;
        if ( $rel =~ /\.p[lm]\z/ && $l =~ /\A=(\w+)/ ) { $pod = $1 ne 'cut'; next }
        next if $pod;
        my $code = $l;
        if ($perl) {
            next if $code =~ /\A\s*#/;
            $code =~ s/\s+#\s.*\z//s;
        }
        else {
            # Markup and script: HTML comments (which may span lines), template
            # comments, and whole-line script comments.
            if ($html) { next unless $code =~ s/\A.*?-->//s; $html = 0 }
            $code =~ s/<!--.*?-->//gs;
            if ( $code =~ s/<!--.*\z//s ) { $html = 1 }
            $code =~ s/\[%#.*?%\]//gs;
            next if $code =~ m{\A\s*(?://|/?\*)};
        }
        for my $r (@RULES) {
            next unless $code =~ $r->[1];
            push @hits, "$rel:$n: $r->[0]: " . substr( $code =~ s/\A\s+|\s+\z//gr, 0, 110 );
            last;
        }
    }
    close $fh;
    return @hits;
}

my ( %count, @new, @detail );
for my $rel (@core) {
    my @hits = naming_lines($rel);
    next unless @hits;
    $count{$rel} = @hits;
    push @detail, @hits;
}

for my $rel ( sort keys %count ) {
    my $allowed = $ALLOWED{$rel} // 0;
    next if $count{$rel} == $allowed;
    if ( $count{$rel} > $allowed ) {
        push @new, "$rel: $count{$rel} lines name an extension, allowed $allowed",
            grep { /\A\Q$rel\E:/ } @detail;
    }
    else {
        push @new, "$rel: $count{$rel} lines name an extension, under its $allowed - "
            . "lower %ALLOWED to $count{$rel}";
    }
}
for my $rel ( sort keys %ALLOWED ) {
    next if $count{$rel};
    push @new, "$rel: names no extension now - remove it from %ALLOWED";
}

is( scalar @new, 0, 'core names no extension beyond the allow-list, and the list is exact' )
    or diag( join( "\n", @new )
        . "\n\nCore names no extension (SM1369, ruling 55): what an extension needs from core "
        . "is a generic hook its descriptor declares (owns.hooks, Lazysite::Extensions::Hooks), "
        . "not a line here that knows it by name. A count that FELL is the allow-list "
        . "shrinking - lower it in this file." );

done_testing();
