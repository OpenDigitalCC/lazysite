#!/usr/bin/perl
# SM863: a claim link that has no host says so, instead of being printed under
# the words "send this link".
#
# `_claim_url` accepts the site base only when it matches ^\w+://[^/\s]+ and
# otherwise returns a bare path. On the CLI that happens TWO ways, and they were
# indistinguishable in the output:
#
#   no site_url at all                -> /claim?u=...
#   site_url: https://${SERVER_NAME}  -> /claim?u=...
#
# The second is the one that bites: it is the CORRECT form for a site served on
# more than one host, it works perfectly under the CGI, and it collapses to
# `https://` on a command line because there is no SERVER_NAME in the
# environment. So the operator who configured it properly gets the same unusable
# output as one who configured nothing.
#
# The empty fallback is RIGHT - guessing a hostname and printing it inside a
# credential-bearing URL would send people to the wrong host - and the primary
# host is not readable anyway (the domains store records it as the literal
# "(default)"). The defect is the silence, not the fallback.
#
# WHY THIS MATTERS FOR THE EXPO: 1314E-05 established that `account-approve` is
# reachable only from the CLI, so the operator approving a registration is
# ALWAYS in the case where the host cannot resolve. Handing them a path is
# handing them a link they cannot send.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root  = repo_root();
my $users = "$root/tools/lazysite-users.pl";

# A fresh docroot with a given lazysite.conf body.
sub site_with {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n$conf";
    close $fh;
    return $d;
}

sub setup_sysop_out {
    my ($conf) = @_;
    my $d = site_with($conf);
    return scalar qx($^X \Q$users\E --docroot \Q$d\E setup-sysop --user sjm 2>&1);
}

subtest 'an absolute site_url gives a link, and says nothing extra' => sub {
    my $out = setup_sysop_out("site_url: https://example.test\n");
    like( $out, qr{https://example\.test/claim\?u=sjm}, 'the full URL is printed' );
    unlike( $out, qr/PATH ONLY/i, 'and it is not announced as a path' );
};

subtest 'no site_url: the path is named as a path, with the cause' => sub {
    my $out = setup_sysop_out('');
    like( $out, qr{/claim\?u=sjm}, 'the path is still given - it is the useful half' );
    like( $out, qr/PATH ONLY/i,
        'but it is NOT presented as a sendable link' )
        or diag( 'It was printed under "Send this single-use self-service link '
            . 'to \'sjm\'", which is a sentence about something the operator '
            . 'cannot send.' );
    like( $out, qr/site_url/,
        'and the message names the setting that would fix it' );
};

subtest 'a placeholder site_url is the SAME case, and says so too' => sub {
    # The one that looks configured and is not, on the CLI.
    my $out = setup_sysop_out( 'site_url: https://${SERVER_NAME}' . "\n" );
    unlike( $out, qr{https://\S*/claim}, 'no half-built absolute URL is emitted' );
    like( $out, qr/PATH ONLY/i, 'it is named as a path' )
        or diag( 'A site_url of https://${SERVER_NAME} resolves only under the '
            . 'web server. On the CLI it becomes "https://" and fails the '
            . 'absolute test, exactly as an absent site_url does.' );
};

subtest 'the API does not put a path in a key called url' => sub {
    # account-approve, because that is the action whose reply carries this value
    # and the one the expo's self-service flow calls (SM858).
    my $d   = site_with('');
    my $req = "$d/req.json";
    open my $rf, '>', $req or die $!;
    print {$rf} '{"action":"account-approve","username":"applicant",'
        . '"email":"a@example.test"}';
    close $rf;
    my $out = qx($^X \Q$users\E --docroot \Q$d\E --api < \Q$req\E 2>&1);

    # The tool logs to stdout before the reply, so take the JSON object rather
    # than the whole stream - decoding the lot fails on the first log line and
    # reads as "no claim was minted", which is not what went wrong.
    my ($json) = $out =~ /^(\{.*\})\s*$/m;
    require JSON::PP;
    my $r = eval { JSON::PP::decode_json( $json // '' ) } || {};
    ok( $r->{claim}, 'the approval minted a claim' ) or diag($json);

    # `url` is either absolute or absent. A caller cannot be expected to
    # pattern-match a field named url to discover it is a path.
    if ( defined $r->{url} ) {
        like( $r->{url}, qr{^\w+://},
            'url, when present, is absolute' )
            or diag( 'SM858 returns this value to whoever approved a '
                . 'registration. A path in a field named url is a wrong answer '
                . 'that looks like a right one.' );
    }
    else {
        ok( 1,                  'url is absent when it cannot be built' );
        ok( defined $r->{path}, 'and the relative form is offered under its own name' )
            or diag( 'The caller still needs the path - it just must not be '
                . 'called a url.' );
    }
};

done_testing();
