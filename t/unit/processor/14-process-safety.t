#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

# Exercise lazysite-manager-api.pl's plugin-list action. It spawns one
# subprocess per candidate script (--describe) with alarm(2). These tests
# verify:
#   - the result is valid JSON with the expected shape
#   - Perl processes do not proliferate (no leaked children)
#   - core scripts (processor, manager-api itself) are NOT in the list

my $root = repo_root();

# We need the plugin discovery to find scripts at $DOCROOT/..  — set up
# a fake repo structure that points back at the real scripts.
my $tmp = tempdir( CLEANUP => 1 );
my $fake_root = "$tmp/fake-repo";
my $docroot   = "$fake_root/public_html";
make_path( "$docroot/lazysite/cache",
           "$fake_root/tools",
           "$fake_root/plugins" );

# Symlink each discoverable script so plugin-list can spawn them.
# D022: plugins moved under plugins/ (form-handler, form-smtp, log,
# audit, payment-demo), core scripts stay at root.
for my $rel ( qw(
    lazysite-auth.pl
    lazysite-manager-api.pl
    lazysite-processor.pl
    plugins/form-handler.pl
    plugins/form-smtp.pl
    plugins/payment-demo.pl
    plugins/log.pl
    plugins/audit.pl
) ) {
    symlink "$root/$rel", "$fake_root/$rel";
}

# Minimal conf (manager-api requires to check manager_groups)
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Test\n";
close $cf;

sub count_perl_procs {
    my @lines = split /\n/, `ps -eo pid,command 2>/dev/null`;
    return scalar grep { /\bperl\b/ && !/grep/ } @lines;
}

my $before = count_perl_procs();

my $script = "$fake_root/lazysite-manager-api.pl";
my $out;
{
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}      = $docroot;
    $ENV{REQUEST_METHOD}     = 'GET';
    $ENV{QUERY_STRING}       = 'action=plugin-list';
    $ENV{HTTP_X_REMOTE_USER} = 'admin';
    $out = qx($^X \Q$script\E 2>/dev/null);
}

# Strip CGI headers before JSON parse
$out =~ s/\A.*?\r?\n\r?\n//s;

my $data = eval { decode_json($out) };
ok( ref $data eq 'HASH', 'plugin-list returns JSON hash' )
    or diag("Raw output: $out");

SKIP: {
    skip "no JSON body", 10 unless ref $data eq 'HASH';

    is( $data->{ok}, 1, 'plugin-list ok=1' );
    ok( ref $data->{plugins} eq 'ARRAY', 'plugins is array' );

    my @ids = map { $_->{id} // '' } @{ $data->{plugins} };
    # SM028: processor is listed server-side (id=lazysite) so the
    # manager config page can discover its script path. The config
    # UI filters it out of the togglable plugin registry — that's
    # a UI concern, not an API one.
    ok( ( grep { $_ eq 'lazysite' } @ids ),
        'core processor (id=lazysite) IS listed for UI discovery' );

    ok( scalar @{ $data->{plugins} } > 0,
        'at least one plugin discovered' );

    for my $p ( @{ $data->{plugins} } ) {
        ok( defined $p->{id},      "plugin has id ($p->{id})" );
        ok( defined $p->{name},    "plugin has name" );
        ok( defined $p->{_script}, "plugin has _script field" );
    }
}

# Allow any still-finishing children to exit (alarm=2 in manager-api).
sleep 3;

my $after = count_perl_procs();
my $diff  = $after - $before;
ok( $diff <= 5,
    "process count did not balloon (before=$before after=$after diff=$diff)" );

done_testing();
