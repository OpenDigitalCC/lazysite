#!/usr/bin/perl
# SM876: the apply sheet's readiness block reads the ids and fields
# `domain-check` actually returns.
#
# It read `chk.dns.ok`, `chk.tls.ok` and `chk.vhost.ok`. domain_check returns
#
#     { ok, host, all_pass, checks: [ { id, label, pass, detail }, ... ] }
#
# so `checks` is an ARRAY not a map, the ids are dns/host/ssl/terminates - no
# `tls`, no `vhost` - and the field is `pass`, not `ok`. Every one of those
# lookups was undefined, `undefined === false` is false, and the warning branch
# was therefore UNREACHABLE: the green "is resolving and served" tick rendered
# unconditionally, for every host, including one whose DNS did not resolve.
#
# WHY A LINT AND NOT A UNIT TEST. Nothing executes this JavaScript. t/lint/136
# renders each manager page and parses its scripts, so a syntax error is caught
# and a wrong field name is not - the page is valid JavaScript reading keys that
# are not there. The defect is a DISAGREEMENT BETWEEN TWO FILES, which is what a
# lint is for: the same shape as t/lint/58 (the action reference against the
# dispatch chain) and t/lint/81 (the capability list against its copy).
#
# It took a person walking tier-B B6 with a deliberately unpointed domain to see
# it, four releases after the code shipped.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    local $/;
    return <$fh>;
}

my $domains = slurp("$root/lib/Lazysite/Manager/Domains.pm");
my $sheet   = slurp("$root/starter/manager/backups.md");
ok( $domains, 'Domains.pm is readable' ) or do { done_testing(); exit };
ok( $sheet,   'the apply sheet is readable' ) or do { done_testing(); exit };

# --- what domain_check EMITS, read from the source of truth ------------------
my ($body) = $domains =~ /sub domain_check\b(.*?)\n\}/s;
ok( $body, 'domain_check was located' ) or do { done_testing(); exit };

my %EMITS;
while ( $body =~ /\bid\s*=>\s*'([a-z_]+)'/g ) { $EMITS{$1} = 1 }
cmp_ok( scalar keys %EMITS, '>=', 3, 'its check ids were extracted' )
    or diag( 'If this drops, the shape changed and every assertion below is '
        . 'vacuous rather than passing.' );

# The readiness block, isolated - so a mention of `tls` elsewhere on the page
# (there is none today, but there might be) cannot mask or cause a failure.
my ($ready) = $sheet =~ /(if \(chk && chk\.ok\).*?\n    \})/s;
ok( $ready, 'the readiness block was located in the apply sheet' )
    or do { done_testing(); exit };

# --- it must not invent ids the engine never emits ---------------------------
for my $bogus (qw(tls vhost)) {
    ok( $ready !~ /\bchk\.\Q$bogus\E\b/,
        "the readiness block does not read a '$bogus' key" )
        or diag( "domain_check emits ids: "
            . join( ', ', sort keys %EMITS )
            . " - there is no '$bogus', so this lookup is undefined and the "
            . 'comparison against it can never be true.' );
}

# --- and it must not index `checks` as if it were a map ----------------------
ok( $ready !~ /\bchk\.(?:dns|host|ssl|terminates)\b/,
    'it does not index the checks array by id as though it were a map' )
    or diag( '`checks` is an ARRAY of { id, label, pass, detail }. Indexing it '
        . 'by name yields undefined for every id, including the real ones.' );

# --- it reads the field the engine writes ------------------------------------
like( $ready, qr/\.pass\b/, "it reads `pass`, the field domain_check sets" );
ok( $ready !~ /\.ok === false/,
    'and not `.ok === false`, which was undefined === false, i.e. never true' );

# --- the three states are distinguished --------------------------------------
#
# `pass` is 1, 0 or NULL, and null is deliberate: behind a proxy the server
# cannot know its own public IP, so "Points to this server" is indeterminate.
# A two-state reading has to get one of those wrong.
like( $body, qr/pass\s*=>\s*undef/,
    'domain_check really does emit an indeterminate pass' );
like( $ready, qr/=== null|=== undefined/,
    'and the sheet distinguishes indeterminate from failed' )
    or diag( 'Treating null as failed warns on every proxied site; treating it '
        . 'as passed asserts reachability nobody established.' );
like( $ready, qr/all_pass/,
    'the green tick is claimed from all_pass, not from an empty problem list' );

done_testing();
