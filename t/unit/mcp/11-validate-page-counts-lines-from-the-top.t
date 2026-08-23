#!/usr/bin/perl
# SM488: validate_page flagged ISO dates as phone numbers, and reported every
# line short by the front matter.
#
# REPORTED FROM THE FIELD on 0.10.26. Three public-phone warnings on a page
# with no phone number and no run of seven digits. Two faults, each minor,
# unfixable together from outside:
#
#   - the phone pattern matched 2026-08-22. The page had exactly three dates
#     and produced exactly three warnings - two of them the filenames of this
#     project's own inbox filings, so any page citing a dated document tripped
#     it.
#   - every line number was short by the front-matter length plus the two
#     fences. Reported 15/58/59, actual 24/67/68, delta 9.
#
# The reader opens line 15, finds a canonical link, and concludes the tool is
# broken - nearly right and completely useless, when a correct line number
# would have put the date under their cursor and made the regex fault obvious.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nmcp_enabled: true\n";
close $c;
my $stub = "$docroot/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
    . "print encode_json({ ok => 1, settings => { manage_content => 1, mcp => 1 } });\n";
close $sf;
chmod 0755, $stub;

sub validate {
    my ($content) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
        params => { name => 'validate_page', arguments => { content => $content } } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT} = $docroot; $ENV{REQUEST_METHOD} = 'POST';
    $ENV{CONTENT_LENGTH} = length $body; $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION} = 'Bearer tester:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body; close $in;
    my $resp = do { local $/; <$out> }; close $out; waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $d = eval { decode_json($jb) } || {};
    return eval { decode_json( $d->{result}{content}[0]{text} // '' ) } || {};
}
sub phones { grep { $_->{kind} eq 'public-phone' } @{ $_[0]{warnings} || [] } }

# THE FIELD AGENT'S PAGE, in shape: seven lines of front matter, then a body
# whose only digit-runs are three ISO dates - two of them inside filenames.
my $page = join "\n",
    '---',                                   # 1
    'title: Data test',                      # 2
    'subtitle: a live A/B',                  # 3
    'ttl: 60',                               # 4
    'tt_page_var:',                          # 5
    '  rows: db:paintings',                  # 6
    '  ctrl: scan:/',                        # 7
    'register:',                             # 8
    '---',                                   # 9
    '',                                      # 10
    'See 2026-08-22-data-plugin-full-run.md for the history.',   # 11
    'and 2026-08-22-data-plugin-on-edge.md for the 500.',        # 12
    'Updated 2026-08-23.',                                       # 13
    '';

subtest 'AN ISO DATE IS NOT A PHONE NUMBER' => sub {
    my @p = phones( validate($page) );
    is( scalar @p, 0, 'a page with three dates and no phone produces no phone warning' )
        or diag( 'Lines reported: ' . join( ',', map { $_->{line} } @p )
            . ' - the regex matched 2026-08-22, ten characters of digits and hyphens.' );
};

subtest 'A REAL NUMBER STILL FIRES, AT THE RIGHT LINE' => sub {
    ( my $with = $page ) =~ s/Updated 2026-08-23\./Ring 01234 567 890 today, updated 2026-08-23./;
    my @p = phones( validate($with) );
    is( scalar @p, 1, 'one phone warning' );
    is( $p[0]{line}, 13, 'reported at the line it is ON, counted from the top of the file' )
        or diag( "reported line $p[0]{line}. The scan ran over the body with a "
            . 'counter from zero, so every number was short by the front matter '
            . 'plus the two fences - here, 9. Reported 15/58/59 meant 24/67/68.' );
};

subtest 'the offset is the front matter, whatever its length' => sub {
    my $short = "---\ntitle: T\n---\n\nRing 01234 567 890.\n";    # fm 1 line + 2 fences = 3
    my @p = phones( validate($short) );
    is( $p[0]{line}, 5, 'a one-line front matter offsets by three' );
    my $none = "Ring 01234 567 890 on line one.\n";
    @p = phones( validate($none) );
    is( $p[0]{line}, 1, 'and no front matter offsets by nothing' )
        or diag( 'A page without front matter must not gain a phantom offset.' );
};

done_testing();
