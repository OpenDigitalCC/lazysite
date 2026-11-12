#!/usr/bin/perl
# n823 (SM1444, ruling 245): the bad-URL blocker counts probes for credential files.
# Scanners fish for the dot-directories of developer and cloud tools and for app config
# files no lazysite site serves. Each new path counts as a bad URL; /app.js and
# /app.config.js do NOT (a real site can serve them); an ordinary page does not; a site's
# `bad_url_extra` still adds to the list; and the stats noise set carries the same names.
#
# Sabotage: take the SM1444 block out of $BAD_RE in lib/Lazysite/BadUrl.pm and the
# "counts" subtests fail (fails on 299a10408, where none of these paths counted).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::BadUrl qw(is_bad_url is_blocked);

my $root = repo_root();

my @counts = qw(
    /.docker/config.json /.claude/settings.json /.claude/.credentials.json
    /.cursor/mcp.json /.aws/credentials /.kube/config /.azure/accessTokens.json
    /.vscode/sftp.json /.idea/dataSources.xml /.terraform/terraform.tfstate
    /.gnupg/secring.gpg /appsettings.json /appsettings.Production.json
    /api/appsettings.Development.json /aws-exports.js /src/aws-exports.js
    /wp-json/batch/v1 /blog/wp-json/batch/v1
);
my @never = qw(
    /app.js /app.config.js /assets/app.js /about /blog/my-post /docker-notes
    /claude-code /cursor-tips /appsettings-guide /aws-guide /wp-json-notes
);

for my $p (@counts) { ok( is_bad_url($p), "$p counts as a bad URL" ) }
for my $p (@never)  { ok( !is_bad_url($p), "$p does not count" ) }

# A site's own list still adds to the built-ins, and does not replace them.
ok(  is_bad_url( '/my-trap',          ['/my-trap'] ), 'bad_url_extra still adds a pattern' );
ok(  is_bad_url( '/.docker/config.json', ['/my-trap'] ), 'and the built-ins still count beside it' );
ok( !is_bad_url( '/app.js',           ['/my-trap'] ), 'and /app.js still does not count' );

# Through the guard, as the auth wrapper calls it: one hit at threshold 1 blocks.
my $d = site_tempdir();
make_path("$d/lazysite/cache");
my $n = 0;
for my $p ( '/.docker/config.json', '/appsettings.json', '/aws-exports.js', '/.claude/settings.json' ) {
    my $ip = '203.0.113.' . ++$n;
    my $r = Lazysite::BadUrl::guard(
        docroot => $d, ip => $ip, path => $p,
        conf_lines => ["bad_url_threshold: 1\n"],
    );
    ok( $r && is_blocked( $d, $ip ), "$p, once at threshold 1, blocks the address" );
}
my $r = Lazysite::BadUrl::guard(
    docroot => $d, ip => '203.0.113.99', path => '/app.js',
    conf_lines => ["bad_url_threshold: 1\n"],
);
ok( !$r && !is_blocked( $d, '203.0.113.99' ), '/app.js, at threshold 1, blocks nobody' );

# The stats extension's noise set mirrors the list: the SM1444 block is the same text.
sub block_of {
    my ($file) = @_;
    open my $fh, '<', "$root/$file" or die "$file: $!";
    local $/;
    my $t = <$fh>;
    $t =~ /(# SM1444 \(ruling 245\).*?wp-json\/batch\n)/s or return '';
    return $1;
}
my $a = block_of('lib/Lazysite/BadUrl.pm');
ok( length $a, 'BadUrl.pm carries the SM1444 block' );
is( block_of('extensions/stats.pl'), $a, 'extensions/stats.pl carries the same block' );

done_testing;
