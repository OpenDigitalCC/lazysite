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
# NAMING AN EXTENSION is naming it by its own name (%NAMED): Odoo's are odoo,
# OOM and oomd, the measure the proposal's inventory used (M-2), and they cover
# its script name (`extensions/odoo.pl`) too. Ruling 136 (2026-11-06): the lint
# counts Odoo's names only, not every extension's script name, so that X7, which
# moves Odoo out, empties the allow-list. The other extensions (data, stats,
# briefs, remap and the rest) are not counted; they are an ordinary word a
# pattern cannot tell from prose, and a ruling of their own decides them.
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
# the payload that leaves core with it. Odoo's browser helper, its sign-in page
# and component; its modules (engine, services) are in its payload lib,
# extensions/odoo/lib, since SM1369 X7 part one, outside the lib/ scanned here.
my %OWN = (
    odoo => [
        # SM1369 X5: the browser helper and the sign-in component are in the
        # payload (extensions/odoo/assets, extensions/odoo/templates), outside the
        # files scanned here; the sign-in system page stays until H-10's rest.
        qr{\Astarter/lazysite/templates/system/odoo-signin\.md\z},
    ],
);

# An extension's own name, where a pattern can tell it from prose. A letter on
# either side is another word (room, zoom); a capital after it is a compound
# (OdooEndpoint), which names it.
my %NAMED = ( odoo => qr{(?<![A-Za-z])(?:[Oo]doo|ODOO|[Oo]om|OOM)d?(?![a-z])} );

# The allow-list: each core file's count of lines naming Odoo, measured on
# 2026-11-06 at b7f178856 and recounted for ruling 136 (Odoo's names only): 43
# files; 42 since X7 part one moved the oomd service into Odoo's payload lib; 34
# since X2 (the actions, capabilities and refusal kinds are declared); 27 since
# X3 (SM1369, n769) put the page sources (sources.pm, auth.pm, app.pm,
# Config.pm, Validate.pm, one line of the processor) and the handler type
# (Handlers.pm, AddressRefs.pm) on their hooks; 24 since X5's asset part moved the
# helper, the component and the banner behind hooks (SM1369 X5); 18 since X4 (n781)
# made the Odoo site sign-in an identity provider (H-1): the session, its log
# names, the display name, the sign-in page, the login option and the
# maintenance exemption; 15 since X5's endpoint kit and services (n782): the
# supervisor, the warm-fork parent and its wire read the declared services and
# the warm endpoint; 14 since X6's checks (n782): the Odoo checks are the
# extension's, declared; 13 since X6's panels (n782, ruling 188): the Unknown
# Odoo writes panel is the extension's own manager page. It may only shrink.
my %ALLOWED = (
    'installers/apache/vhost-fcgi.conf.example'  => 1,
    'installers/hestia/lazysite-fcgi.stpl'       => 1,
    'installers/hestia/lazysite-fcgi.tpl'        => 1,
    'installers/nginx/vhost-fcgi.conf.example'   => 1,
    'lazysite-processor.pl'                      => 2,
    'lazysite-processor/front-door.pm'           => 6,     # X3, X5: the pool preloads no Odoo module; the hook modules load on first use; a warm endpoint is declared (n782)
    'lib/Lazysite/Auth/GroupRefs.pm'             => 7,    # SM1387: a binding's and odoo.conf's group names
    'starter/manager/config.md'                  => 2,
    'tools/bench-surfaces.pl'                    => 69,
    'tools/coverage-groups.pl'                   => 1,
    'tools/ext-compat.sh'                        => 18,
    'tools/lazysite-server.pl'                   => 1,
    'tools/precheck-areas.pl'                    => 3,
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

my @RULES = map { [ "the $_ extension by name", $NAMED{$_} ] } sort keys %NAMED;

# Ruling 136: Odoo's names are counted, its script name with them; another
# extension's script name is not.
ok( ( grep { "my \$x = 'extensions/odoo.pl';" =~ $_->[1] } @RULES ), "Odoo's script name is counted" );
for my $s ( grep { $_ ne 'odoo' } @stems ) {
    my $line = "my \$x = 'extensions/$s.pl';";
    ok( !( grep { $line =~ $_->[1] } @RULES ), "another extension's script name is not counted ($s)" );
}

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
