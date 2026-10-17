#!/usr/bin/perl
# SM1124 F-3: THE OUTCOME IN THE URL IS A CODE, NEVER A SENTENCE.
#
# The 0.15.9 walk: `?form=zz59-x&outcome=zz59+probe+text` printed "zz59 probe
# text" under the page's content. It was HTML-escaped, so not script injection,
# but anyone could send a link that made a site's own page say their words (a
# phone number, "your account is suspended"). A refusal's sentence travelled in
# `outcome=` because the handler's no-JS redirect carried the prose.
#
# What this holds:
# - a forged `outcome=` of any text renders ONE generic sentence and none of the
#   forged words; so do forged `retry=` / `n=` / `field=` values
# - each real refusal, driven by a real POST through the handler, redirects with
#   a short [a-z-]+ code (and digits only for a number) and the page it lands on
#   shows that refusal's sentence
# - `retry=` inserts digits only
# - the JSON (fetch) path still returns the whole message in its body
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir load_processor setup_minimal_site);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = site_tempdir();
my $SECRET  = 'c' x 64;

make_path( "$docroot/lazysite/forms", "$docroot/lazysite/auth" );
sub put {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}
put( "$docroot/lazysite/lazysite.conf",       "site_name: T\n" );
put( "$docroot/lazysite/forms/handlers.conf", "handlers:\n  - id: store\n    type: file\n    name: Store\n" );
put( "$docroot/lazysite/forms/contact.conf",  "rate_limit: 0\ntargets:\n  - handler: store\n" );
put( "$docroot/lazysite/forms/limited.conf",  "rate_limit: 1\ntargets:\n  - handler: store\n" );
put( "$docroot/lazysite/forms/ruled.conf",    "rate_limit: 0\ntargets:\n  - handler: store\n" );
put( "$docroot/lazysite/forms/ruled.rules",
    '{"form":"ruled","fields":[{"name":"email","type":"email","required":true}]}' );
put( "$docroot/lazysite/forms/.secret", $SECRET );

# One POST. Returns the raw response. JSON asks for the body; otherwise the
# handler answers the way a browser without JavaScript is answered (a 303).
sub submit {
    my (%o)  = @_;
    my $ts   = defined $o{ts} ? $o{ts} : time - 10;
    my $tk   = hmac_sha256_hex( $ts, $SECRET );
    my %f    = ( _form => $o{form} // 'contact', _hp => '', _ts => $ts, _tk => $tk,
        _page => '/contact', %{ $o{fields} // { name => 'x' } } );
    my $body = join '&', map { "$_=$f{$_}" } sort keys %f;
    my $bf   = "$docroot/.body";
    put( $bf, $body );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        ( $o{json} ? ( HTTP_ACCEPT => 'application/json' ) : () ),
    );
    return qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null) // '';
}

load_processor($docroot);

# The page a visitor lands on: the real renderer, given the redirect's query.
sub page_for {
    my ($qs) = @_;
    local $ENV{QUERY_STRING} = $qs;
    return main::convert_fenced_form(
        "::: form\nname | Name | required\nemail | Email | email\nsubmit | Send\n:::\n",
        { form => 'contact' },
    );
}
sub banner_for {
    my ($qs) = @_;
    my ($b) = page_for($qs) =~ m{(<p class="form-status form-status-(?:ok|error)"[^>]*>.*?</p>)}s;
    return $b // '';
}
sub landing {
    my ($raw) = @_;
    my ($loc) = $raw =~ /^Location: (\S+)/m;
    return unless defined $loc;
    my ($qs) = $loc =~ /\?(.*)\z/;
    return $qs;
}

my $GENERIC = 'Your submission could not be accepted. Please try again.';

# --- forged text -------------------------------------------------------------
for my $qs (
    'form=contact&outcome=zz59+probe+text',
    'form=contact&outcome=Call+0800+555+0100+now',
    'form=contact&outcome=expired&retry=zz59+probe',
    'form=contact&outcome=rate&retry=zz59+probe',
    'form=contact&outcome=field-required&field=zz59+probe+text',
    'form=contact&outcome=too-many-files&n=zz59+probe',
    'form=contact&outcome=Too-Quick&zz=1',
    'form=contact&outcome=zz59&text=zz59+probe+text',
    )
{
    my $b = banner_for($qs);
    unlike( $b, qr/zz59|probe|0800|555|Call /i, "forged: no forged words in the banner ($qs)" );
}
for my $qs ( 'form=contact&outcome=zz59+probe+text', 'form=contact&outcome=Rate+limit+exceeded',
    'form=contact&outcome=zz59-probe-text', 'form=contact&outcome=ok-your+account+is+suspended' )
{
    like( banner_for($qs), qr/\Q$GENERIC\E/, "an unknown code is the generic sentence ($qs)" );
    like( banner_for($qs), qr/form-status-error/, 'in the refusal style' );
}

# --- retry inserts digits only ------------------------------------------------
like( banner_for('form=contact&outcome=rate&retry=7'), qr/in about 7 minutes\./, 'retry=7: minutes' );
like( banner_for('form=contact&outcome=rate&retry=1'), qr/in about 1 minute\./,  'retry=1: minute' );
unlike( banner_for('form=contact&outcome=rate&retry=7abc'), qr/7abc/, 'retry with letters is refused' );
like( banner_for('form=contact&outcome=rate&retry=7abc'), qr/\Q$GENERIC\E/, 'and shows the generic sentence' );
like( banner_for('form=contact&outcome=rate'), qr/\Q$GENERIC\E/, 'a rate code without a number is generic' );
like( banner_for('form=contact&outcome=rate&retry=99999'), qr/in about 60 minutes\./, 'retry is capped' );

# --- each real refusal, through the handler ----------------------------------
my %want = (
    'too quick'    => [ { ts => 'now' }, qr/That was too quick - please try again in a moment\./ ],
    'expired'      => [ { ts => 'old' }, qr/This form was open too long and has expired - please reload the page and send it again\./ ],
    'empty'        => [ { fields => { name => '' } }, qr/Please fill in the form before submitting\./ ],
    'field rule'   => [ { form => 'ruled', fields => { email => 'nope', name => 'x' } },
        qr/The &#39;email&#39; field needs an email address\.|The 'email' field needs an email address\./ ],
);
for my $name ( sort keys %want ) {
    my ( $args, $sentence ) = @{ $want{$name} };
    # The timestamp is taken here, not when the table was built: a slow machine
    # would otherwise age the 'now' token past the three-second floor.
    my %a = %$args;
    $a{ts} = $a{ts} eq 'now' ? time : time - 100_000 if defined $a{ts};
    my $raw = submit(%a);
    like( $raw, qr/\AStatus: 303/, "$name: answered with a redirect" );
    my $qs = landing($raw) // '';
    my ($outcome) = $qs =~ /(?:\A|&)outcome=([^&]*)/;
    like( $outcome // '', qr/\A[a-z-]+\z/, "$name: the outcome is a code" ) or diag($raw);
    for my $pair ( split /&/, $qs ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next if $k eq 'form' || $k eq 'outcome';
        like( $v, qr/\A[A-Za-z0-9_.-]+\z/, "$name: parameter $k is one plain token" );
    }
    my $form = $qs =~ /form=([^&]+)/ ? $1 : 'contact';
    local $ENV{QUERY_STRING} = $qs;
    my $page = main::convert_fenced_form(
        "::: form\nname | Name | required\nemail | Email | email\nsubmit | Send\n:::\n",
        { form => $form } );
    like( $page, $sentence, "$name: the page shows its sentence" );
    like( $page, qr/form-status-error/, "$name: in the refusal style" );
}

# --- rate limit: the second post is refused, with retry as digits ------------
{
    my $first = submit( form => 'limited' );
    like( $first, qr/\AStatus: 303/, 'rate: the first post is accepted (redirected)' );
    my $raw = submit( form => 'limited' );
    my $qs  = landing($raw) // '';
    like( $qs, qr/(?:\A|&)outcome=rate(?:&|\z)/, 'rate: outcome=rate' ) or diag($raw);
    like( $qs, qr/(?:\A|&)retry=\d{1,2}(?:&|\z)/, 'rate: retry is a number' );
    local $ENV{QUERY_STRING} = $qs;
    my $page = main::convert_fenced_form(
        "::: form\nname | Name | required\nsubmit | Send\n:::\n", { form => 'limited' } );
    like( $page, qr/Too many submissions of this form from your address in the last hour\. Please try again in about \d+ minutes?\./,
        'rate: the page shows the sentence with the number' );
}

# --- the JSON path keeps the whole message -----------------------------------
{
    my $out = submit( json => 1, ts => time );
    like( $out, qr/"error":"That was too quick - please try again in a moment\."/, 'JSON: the full message' );
}

done_testing();
