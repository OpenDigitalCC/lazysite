#!/usr/bin/perl
# SM264 (from SM251's validation): an agent can force a registry rebuild, so
# "delete then verify" is a complete workflow rather than a wait.
#
# Deleting a page removes it immediately and clears the generated registries, but
# the rebuild happens on the NEXT request for one. Measured on 0.10.4: the page
# 404s at once, the URL was still in sitemap.xml at +20 seconds, and had cleared
# shortly after. So an agent that deletes, checks the sitemap and sees the old
# URL reasonably concludes the delete failed - or starts editing the generated
# registry by hand, which is what happened on one live site before SM251 existed.
#
# The operator's preferred remedy was an action rather than a better error
# message: waiting is not a workflow.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/templates/registries", "$d/sites/clienta" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n"
    . "alias_hosts: a.example\nalias.a.example.content_root: sites/clienta\n";
close $cf;
open my $tt, '>', "$d/lazysite/templates/registries/sitemap.xml.tt" or die $!;
print {$tt} '[% FOREACH p IN pages %][% p.url %][% END %]';
close $tt;
open my $ix, '>', "$d/index.md" or die $!;
print {$ix} "# Home\n";
close $ix;

my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
close $sf;
chmod 0755, $stub;

sub call {
    my ($name) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $name, arguments => {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = eval { decode_json( $jb // '' ) };
    return $r && $r->{result} ? $r->{result}{structuredContent} : undef;
}

# Stale registries in BOTH roots - the multi-domain case SM251 fixed, which a
# docroot-only clear would leave behind.
#
# SM433: SEEDED WHERE THE SERVER READS. SM293 step 3 moved the generated
# registries to lazysite/cache/registries/<key>/<name>; this seeded
# $root/sitemap.xml, the pre-SM293 location, so it asserted the clear removed a
# file nobody serves. The SM251 property under test - both roots cleared, not
# just the docroot - is unchanged; only the location is corrected.
for my $r ( $d, "$d/sites/clienta" ) {
    my $key = $r;
    $key =~ s{\A\Q$d\E/?}{};
    $key =~ s{[^A-Za-z0-9._-]+}{_}g;
    $key = '_root' unless length $key;
    File::Path::make_path("$d/lazysite/cache/registries/$key");
    open my $fh, '>', "$d/lazysite/cache/registries/$key/sitemap.xml" or die $!;
    print {$fh} "stale, still lists /gone\n";
    close $fh;
}

{
    my $r = call('regenerate_registries');
    ok( $r && $r->{ok}, 'regenerate_registries answers' ) or diag encode_json( $r // {} );

    ok( !-f "$d/lazysite/cache/registries/_root/sitemap.xml",
        "the docroot's stale registry is cleared" );
    ok( !-f "$d/lazysite/cache/registries/sites_clienta/sitemap.xml",
        "and the DOMAIN's - a docroot-only clear is the SM251 defect" );

    my @roots = @{ $r->{cleared_roots} || [] };
    ok( ( grep { m{clienta} } @roots ), 'the domain root is reported as cleared' )
        or diag encode_json( \@roots );

    # The caller must be told the rebuild is not instantaneous, or this replaces
    # one wrong conclusion with another.
    like( $r->{note}, qr/next request|force/i,
        'the result says the rebuild happens on the next request' );

    # No filesystem paths leak (SM260): the roots are site-relative.
    is( scalar( grep { m{^/(?:home|srv|var|tmp)/} } @roots ), 0,
        'cleared_roots are site-relative, not filesystem paths' );
}

# Idempotent: running it with nothing to clear is not an error.
{
    my $r = call('regenerate_registries');
    ok( $r && $r->{ok}, 'a second run is a no-op, not a failure' );
}

done_testing();
