#!/usr/bin/perl
# SM1142 S1: THE UPGRADE MOVES A SITE TO extensions/, ONCE, AND IT BEHAVES THE SAME.
#
# Ruled 2026-10-17 (R3): "fixup on upgrade, then its done". After the release
# that carries the rename nothing reads the old directory or the old conf
# spelling, so the upgrade has to convert every place a site holds them, or an
# extension that was on reads as off - the login rate limiter among them, and
# silently. A site as 0.16.3 left it (t/lib/PreRenameSite.pm) is upgraded in
# place and every one of those places is checked: the files, the conf, the
# cgi-bin links, a start page, the old directory itself, the summary, and that a
# second run changes nothing.
#
# Sabotage: with the extensions-rename step taken out of cmd_install, the
# enabled extensions read as off and the old directory stays - this fails.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_manifest_guard repo_root);
use PreRenameSite qw(new_site install make_pre_rename slurp spit);

my $MF_GUARD = repo_manifest_guard();
my $ROOT     = repo_root();

# old-name: begin (SM1142, the test names the layout it upgrades)
my $OLD = 'plugins';

my ( $docroot, $cgibin, $root ) = new_site();
my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
is( $rc, 0, 'the site is provisioned' ) or diag $out;
make_pre_rename( $docroot, $cgibin, $root, qw(data.pl daemon.pl stats.pl site-widget.pl) );

# What the site did to its old directory: edited a shipped copy, added its own
# extension, and linked one into the cgi-bin by hand, as the docs once showed.
spit( "$root/$OLD/stats.pl", slurp("$root/$OLD/stats.pl") . "\n# edited on this site\n" );
spit( "$root/$OLD/site-widget.pl", "#!/usr/bin/perl\nprint qq({\"id\":\"site-widget\",\"name\":\"W\"}\\n) if \"\@ARGV\" eq '--describe';\n" );
symlink "$root/$OLD/form-smtp.pl", "$cgibin/form-smtp.pl" or die $!;
spit( "$docroot/lazysite/auth/user-settings.json",
    '{"ed":{"start_page":"manager:' . $OLD . '"},"jo":{"start_page":"manager:files"}}' );
my @before = sort map { m{^\s+-\s+\Q$OLD\E/(\S+)} ? $1 : () } split /\n/, slurp("$docroot/lazysite/lazysite.conf");
ok( scalar( grep { $_ eq 'login-rate-limit.pl' } @before ), 'the old site has the login rate limiter on' );    # bare-name-on-purpose

( $rc, $out ) = install( $docroot, $cgibin, 'upgrade' );
is( $rc, 0, 'the upgrade succeeds' ) or diag $out;

my $conf = slurp("$docroot/lazysite/lazysite.conf");
unlike( $conf, qr/^\Q$OLD\E\s*:/m, 'the old list header is gone' );
unlike( $conf, qr{^\s+-\s+\Q$OLD\E/}m, 'and so is every old-directory entry' );
is( scalar( () = $conf =~ /^extensions:\s*$/mg ), 1, 'one list, under extensions:' );

require Lazysite::Manager::Extensions;
{
    no warnings 'once';
    local $Lazysite::Manager::Extensions::DOCROOT = $docroot;
    for my $f (@before) {
        ok( Lazysite::Manager::Extensions::extension_enabled("extensions/$f"), "extensions/$f is still on" );
    }
}

ok( !-e "$root/$OLD", 'no old directory is left' );
ok( -f "$root/extensions/site-widget.pl", "the site's own extension moved to extensions/" );
is( slurp("$root/extensions/stats.pl"), slurp("$ROOT/extensions/stats.pl"),
    'an edited shipped copy is replaced by the release, as an edited code file always is' );
like( slurp("$root/extensions/stats.pl.from-plugins") // '', qr/# edited on this site/,
    'and the edit is kept beside it' );
for my $l (qw(form-handler.pl payment-demo.pl form-smtp.pl)) {
    my $t = readlink("$cgibin/$l") // '';
    like( $t, qr{/extensions/\Q$l\E\z}, "the cgi-bin link $l points into extensions/" );
    ok( -f "$cgibin/$l", "and resolves" );
}
like( slurp("$docroot/lazysite/auth/user-settings.json"), qr/"ed":\{"start_page":"manager:extensions"\}/,
    'a start page on the old Extensions page names the new one' );
like( slurp("$docroot/lazysite/auth/user-settings.json"), qr/"jo":\{"start_page":"manager:files"\}/,
    'and another start page is untouched' );
like( $out, qr/Extensions: converted to extensions\/ \(SM1142\)/, 'the summary says what it converted' );
unlike( $out, qr/orphan .*\/\Q$OLD\E\//, 'and does not call a moved copy an orphan' );

# Idempotent: the once marker is recorded, and a run without it changes nothing.
my $state = slurp("$docroot/lazysite/.install-state.json");
like( $state, qr/"extensions-rename"/, 'the step is recorded as done' );
unlike( $state, qr{/\Q$OLD\E/}, 'and the install state records no old-directory path' );
my $sp = "$docroot/lazysite/.install-state.json";
spit( $sp, $state =~ s/"extensions-rename",?//r =~ s/,(\s*\])/$1/r );
my $conf_before = slurp("$docroot/lazysite/lazysite.conf");
( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'a second run succeeds' ) or diag $out;
is( slurp("$docroot/lazysite/lazysite.conf"), $conf_before, 'and leaves the conf as it was' );
unlike( $out, qr/Extensions: converted/, 'with nothing to report' );

# Both headers, the SM915 damaged shape the readers used to merge: the union.
spit( "$docroot/lazysite/lazysite.conf",
    "site_name: T\nextensions:\n  - extensions/data.pl\nauth_default: none\n$OLD:\n  - $OLD/stats.pl\n  - extensions/data.pl\n" );
spit( $sp, slurp($sp) =~ s/"extensions-rename",?//r =~ s/,(\s*\])/$1/r );
( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'a conf carrying both headers upgrades' ) or diag $out;
is( slurp("$docroot/lazysite/lazysite.conf"),
    "site_name: T\nextensions:\n  - extensions/data.pl\n  - extensions/stats.pl\nauth_default: none\n",
    'into one list holding every entry either had' );

# A list written back under the old name later is named by the check.
spit( "$docroot/lazysite/lazysite.conf", slurp("$docroot/lazysite/lazysite.conf") . "$OLD:\n  - $OLD/remap.pl\n" );
my $check = `\Q$^X\E -I\Q$ROOT/lib\E \Q$ROOT/tools/lazysite-check.pl\E --docroot \Q$docroot\E 2>&1`;
like( $check, qr/lazysite\.conf line 6 uses the old name: `\Q$OLD\E:` - write `extensions:`/,
    'lazysite check names an old header, by line' );
like( $check, qr/line 7 uses the old name: `- \Q$OLD\E\/remap\.pl` - write `- extensions\/remap\.pl`/,
    'and an old entry, with the line to write' );
# old-name: end

done_testing();
