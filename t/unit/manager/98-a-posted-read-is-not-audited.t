#!/usr/bin/perl
# SM554: a posted read is not audited.
#
# The manager UI POSTs everything, so a read-only action arrives as a POST
# and reaches the audit block like any write. The audit %skip list is what
# keeps the trail a record of CHANGES: every read-shaped action is listed
# there. notices and layouts-manifest were not, so each POST wrote an `ok`
# row with target '/' - noise an operator has to learn to discount.
#
# This test drives the real dispatcher (the users tool stubbed) and asserts
# that neither read leaves an audit line, while a genuine write still does -
# so the test cannot pass by the audit log being empty for some other reason.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_script);

my $SECRET = 'testsecret0123456789abcdef0123456789abcdef0123456789abcdef012345';
my $d      = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/lazysite/logs");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nsite_url: http://localhost\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print {$sf} "$SECRET\n";
close $sf;

my $stub = "$d/users-stub.pl";
open my $st, '>', $stub or die $!;
print {$st} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { manage_themes => 1, manage_layouts => 1, notifications => 1, ui => 1 }, users => [], groups => {} });
STUB
close $st;
chmod 0755, $stub;

sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $SECRET ) }

sub post {
    my ($qs) = @_;
    return run_script(
        'lazysite-manager-api.pl',
        stdin => '{}',
        env   => {
            DOCUMENT_ROOT         => $d,
            REQUEST_METHOD        => 'POST',
            QUERY_STRING          => $qs,
            CONTENT_LENGTH        => 2,
            HTTP_X_REMOTE_USER    => 'admin',
            LAZYSITE_AUTH_TRUSTED => 1,
            HTTP_X_CSRF_TOKEN     => csrf('admin'),
            LAZYSITE_USERS_TOOL   => $stub,
        }
    );
}

sub audit_lines {
    open my $a, '<', "$d/lazysite/logs/audit.log" or return ();
    my @l = <$a>;
    close $a;
    chomp @l;
    return @l;
}

post('action=notices');
post('action=layouts-manifest');
post('action=theme-activate&path=sky');    # a real write, as the control

my @l = audit_lines();
ok( ( grep { /\| theme-activate \| sky \|/ } @l ),
    'a genuine write (theme-activate) still leaves an audit row' );
ok( !( grep { /\| notices \|/ } @l ), 'a POSTed notices read is not audited' );
ok( !( grep { /\| layouts-manifest \|/ } @l ),
    'a POSTed layouts-manifest read is not audited' );

# The skip list is the mechanism; pin its membership so a future table move
# cannot quietly drop the two names.
{
    open my $fh, '<', "$FindBin::Bin/../../../lazysite-manager-api.pl" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($skip) = $src =~ /my %skip = map \{ \$_ => 1 \} qw\((.*?)\);/s;
    ok( defined $skip, 'the audit %skip list is where it was' );
    my %s = map { $_ => 1 } split ' ', $skip // '';
    ok( $s{notices},            'notices is in the audit %skip list' );
    ok( $s{'layouts-manifest'}, 'layouts-manifest is in the audit %skip list' );
}

done_testing();
