#!/usr/bin/perl
# SM1012: _render_form's observable output, recorded, so a split of the sub can
# be shown to change none of it.
#
# A move is proved by the suite because a move cannot change behaviour; a split
# can, and the suite checks behaviours, not identity. So this records what the
# sub does over a corpus and is the gate every split step of _render_form is
# held to (SM1012, "The proof per step"). Ruled 2026-10-12: the record is
# committed beside this file and regenerated only on a ruled change, so a change
# in the output is a visible diff in review.
#
# THE CORPUS. Every `:::form` block in starter/, docs/, website/ and the t/
# fixtures, each rendered five ways - plain; with every `prefill:` parameter
# declared and given a hostile value; with the `ok`, `ok-processing` and a
# hostile error outcome for its own form - and a set of written cases, one or
# more per rule and field kind, and one for each branch the 0.15.5 gate's
# coverage left unreached in _render_form (forms.pm 246, 255, 433, 508, 616,
# 617, 660, 705; %BRANCH below names them).
#
# WHAT IS RECORDED per case: the HTML; the `.rules` sidecar as data (it is
# encode_json of a hash, so its BYTES vary with Perl's hash order from run to
# run - the data is what is fixed); every log_event call; and any warning,
# which fails the case outright (a `next` or `last` that leaves a sub warns -
# SM1012 Risks). The time/token placeholders are left as placeholders, as the
# sub leaves them; the stylesheet's ?v= is masked, being the install's version.
#
# TWO OUTCOMES NO INPUT REACHES, so no case is written for them (forms.pm at
# 0.15.5): `last unless length $rs` (272) and the false side of
# `$rs =~ s/^(\S+)//` (351), with the `else { last }` beside them. The line is
# trimmed of whitespace at both ends, the rules are a suffix of it, and each
# pass takes a prefix; so a non-empty remainder ends in a non-space and is never
# all whitespace (272), and one that matched /^[A-Za-z]+:"/ starts with a
# non-space (351). An exhaustive run over every line of up to seven characters
# from `a p : " \ |`, space and tab reached neither.
#
#   LAZYSITE_CHARACTERISE=write prove -l t/unit/processor/112-*.t   # re-record
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Find     qw(find);
use File::Path     qw(make_path);
use JSON::PP       ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor repo_root site_tempdir);

no warnings 'once';    # the processor's globals are named here once each

my $RECORD = "$FindBin::Bin/112-the-form-renderer-is-characterised.json";
my $WRITE  = ( $ENV{LAZYSITE_CHARACTERISE} // '' ) eq 'write';
my $JSON   = JSON::PP->new->utf8->canonical->pretty;

my $docroot = site_tempdir();
load_processor($docroot);
my $ldir = dirname($docroot) . '/engine';
make_path("$ldir/forms");

# A value that is not a fixed point of any escaping this sub does (SM868), nor
# of a change of case.
my $HOSTILE = qq{A&b <i>"Q"</i> 'x' [% site %] \x{c9}t\x{e9}};

# The branches the 0.15.5 gate left unreached, and the case that reaches each.
my %BRANCH = (
    'forms.pm:246 a blank line is skipped'              => 'blank-lines-between-fields',
    'forms.pm:255 a line with no name is skipped'       => 'a-line-with-no-name',
    'forms.pm:433 query_params that is not a list'      => 'prefill-without-query-params',
    'forms.pm:508 a number field with no max or min'    => 'number-without-bounds',
    'forms.pm:616 a number field with no min'           => 'number-without-bounds',
    'forms.pm:617 a number field with no max'           => 'number-without-bounds',
    'forms.pm:660 a form with no fields at all'         => 'only-step-delimiters',
    'forms.pm:705 a page path that is not a local path' => 'page-path-protocol-relative',
);

sub run_case {
    my ($c) = @_;
    my ( @log, @warn );
    no warnings 'redefine';
    local *main::log_event = sub {
        my ( $level, $context, $message, %extra ) = @_;
        push @log, { level => $level, context => $context, message => $message, extra => \%extra };
        return;
    };
    local $SIG{__WARN__}      = sub { push @warn, $_[0] };
    local %main::RENDER_QUERY = %{ $c->{query} || {} };
    local $main::LAZYSITE_DIR = $ldir;
    local $ENV{REDIRECT_URL}  = $ENV{REDIRECT_URL};
    local $ENV{QUERY_STRING}  = $ENV{QUERY_STRING};
    for my $k (qw(REDIRECT_URL QUERY_STRING)) {
        if ( defined $c->{env}{$k} ) { $ENV{$k} = $c->{env}{$k} }
        else                         { delete $ENV{$k} }
    }
    my $name = $c->{meta}{form} // '';
    my $side = "$ldir/forms/$name.rules";
    unlink $side if length $name;
    my $html = main::_render_form( $c->{body}, $c->{meta} );
    $html =~ s/(lazysite-chrome\.css\?v=)[^"]*/${1}VERSION/g;
    my $rules;
    if ( length $name && -e $side ) {
        open my $fh, '<', $side or die "$side: $!";
        local $/;
        $rules = JSON::PP::decode_json(<$fh>);
        close $fh;
        unlink $side;
    }
    return { html => $html, rules => $rules, log => \@log, warnings => \@warn };
}

# --- the corpus, read from the tree when recording ---

sub corpus_blocks {
    my $root = repo_root();
    my %seen;
    my @out;
    my @files;
    find(
        sub { push @files, $File::Find::name if -f && /\.(?:md|t)\z/ },
        map { "$root/$_" } qw(starter docs website t)
    );
    for my $f ( sort @files ) {
        ( my $rel = $f ) =~ s{\A\Q$root\E/}{};
        open my $fh, '<', $f or die "$rel: $!";
        my $text = do { local $/; <$fh> };
        close $fh;
        my ($form) = $text =~ /^form:\s*([A-Za-z0-9_-]+)\s*$/m;
        my $n = 0;
        # The opening and closing fences as convert_fenced_form matches them.
        while ( $text =~ /^:::[ \t]*form[ \t]*\n(.*?)^:::[ \t]*\n/gsm ) {
            my $body = $1;
            $n++;
            next if $seen{$body}++;
            push @out, { from => "$rel#$n", body => $body, form => $form // 'corpus' };
        }
    }
    return @out;
}

sub corpus_cases {
    my @cases;
    for my $b ( corpus_blocks() ) {
        my %meta   = ( form => $b->{form} );
        my @params = $b->{body} =~ /\bprefill:(\S+)/g;
        my $page   = { REDIRECT_URL => '/page', QUERY_STRING => '' };
        my $id     = $b->{from};
        push @cases, { id => "$id plain", body => $b->{body}, meta => {%meta}, env => $page };
        push @cases, {
            id    => "$id prefill",
            body  => $b->{body},
            meta  => { %meta, query_params => [@params] },
            query => { map { $_ => $HOSTILE } @params },
            env   => $page,
        } if @params;
        for my $o ( 'ok', 'ok-processing', 'Sorry%2C+%3Cb%3Eno%3C%2Fb%3E+%C3%A9+%5B%25+x+%25%5D' ) {
            push @cases, {
                id   => "$id outcome=$o",
                body => $b->{body},
                meta => {%meta},
                env => { REDIRECT_URL => '/page', QUERY_STRING => "form=$b->{form}&outcome=$o" },
            };
        }
    }
    return @cases;
}

# --- the written cases ---

sub written_cases {
    my $page = { REDIRECT_URL => '/contact', QUERY_STRING => '' };
    my @c;
    my $add = sub {
        my ( $id, $body, %o ) = @_;
        push @c, {
            id    => $id,
            body  => $body,
            meta  => $o{meta}  // { form => 'w' },
            query => $o{query} // {},
            env   => $o{env}   // $page,
        };
    };

    # The guard.
    $add->( 'no-form-key',                   "name | Name | required\n", meta => {} );
    $add->( 'form-name-the-sidecar-refuses', "name | Name\n", meta => { form => 'bad name' } );

    # The line loop's head.
    $add->( 'blank-lines-between-fields', "name | Name\n\n   \nemail | Email | email\n" );
    $add->( 'a-line-with-no-name',        "| Label only | required\nname | Name\n" );
    $add->( 'name-only-no-label',         "name\n" );
    $add->( 'submit-only',                "submit | Send\n" );
    $add->( 'submit-with-markup',         "name | Name\nsubmit | Send <b>now</b>\n" );

    # Steps.
    $add->( 'two-titled-steps',
        "--- step: About you ---\nname | Name | required\n--- step: Detail ---\nmsg | Message | textarea\nsubmit | Send\n" );
    $add->( 'a-leading-delimiter-and-an-untitled-step',
        "--- step ---\n--- step ---\nname | Name\n------ STEP ------\nage | Age | number\n" );
    $add->( 'only-step-delimiters', "--- step: One ---\n--- step ---\n" );
    $add->( 'empty-body',           '' );

    # The tokeniser.
    $add->( 'quoted-placeholder-and-value',
        qq{name | Name | placeholder:"Your full name" value:"Ann Smith" required\n} );
    $add->( 'quoted-value-with-an-escaped-quote', qq{q | Quote | value:"before \\" after" max:9\n} );
    $add->( 'unclosed-quote-is-warned', qq{q | Quote | value:"never closed required\n} );
    $add->( 'pattern-takes-the-rest-of-the-line', "phone | Phone | required pattern:[0-9 ()+.-]{6,30}\n" );
    $add->( 'quoted-pattern-then-a-rule', qq{code | Code | pattern:"[A-Z]{3} [0-9]+" required\n} );
    $add->( 'unknown-and-malformed-rules-ignored', "x | X | bogus max:abc min: capture:front accept:\n" );
    $add->( 'a-trailing-pipe-in-the-rules', "x | X | required |\n" );

    # Input types and their attributes.
    $add->( "type-$_", "f | F | $_\n" ) for qw(email tel date time number url password);
    $add->( 'tel-with-its-own-pattern', "f | F | tel pattern:[0-9]{3}\n" );
    $add->( 'number-with-bounds',       "n | N | number min:2 max:9 required\n" );
    $add->( 'number-without-bounds',    "n | N | number\n" );
    $add->( 'text-with-max',            "t | T | max:40 optional\n" );
    $add->( 'hostile-placeholder',      qq{t | T | placeholder:"a&b \\"q\\" <x>"\n} );

    # The value and the prefill gate.
    $add->( 'value-hostile-literal', qq{t | T | value:"a&b <i>'q'</i> [% site %]"\n} );
    $add->(
        'prefill-declared-and-present', "c | Code | prefill:c\n",
        meta  => { form => 'w', query_params => ['c'] },
        query => { c    => $HOSTILE }
    );
    $add->(
        'prefill-declared-and-empty', qq{c | Code | value:"LIT" prefill:c\n},
        meta  => { form => 'w', query_params => ['c'] },
        query => { c    => '' }
    );
    $add->(
        'prefill-declared-and-absent', qq{c | Code | value:"LIT" prefill:c\n},
        meta => { form => 'w', query_params => ['c'] }
    );
    $add->(
        'prefill-undeclared', "c | Code | prefill:c\n",
        meta  => { form => 'w', query_params => ['other'] },
        query => { c    => $HOSTILE }
    );
    $add->(
        'prefill-without-query-params', "c | Code | prefill:c\n",
        meta  => { form => 'w' },
        query => { c    => $HOSTILE }
    );
    $add->(
        'prefill-query-params-not-a-list', "c | Code | prefill:c\n",
        meta  => { form => 'w', query_params => 'c' },
        query => { c    => $HOSTILE }
    );
    $add->(
        'textarea-prefilled', "m | Message | textarea max:50 placeholder:Say prefill:m required\n",
        meta  => { form => 'w', query_params => ['m'] },
        query => { m    => $HOSTILE }
    );
    $add->( 'textarea-plain', "m | Message | textarea\n" );

    # File.
    $add->( 'file-plain', "f | File | file\n" );
    $add->( 'file-every-attribute', "f | File | file accept:image/*,.pdf multiple capture required\n" );
    $add->( 'file-capture-user',         "f | File | file capture:user\n" );
    $add->( 'file-capture-environment',  "f | File | file capture:environment\n" );
    $add->( 'file-capture-not-a-camera', "f | File | file capture:front\n" );
    $add->( 'file-beats-textarea',       "f | File | textarea file\n" );

    # Choosers.
    $add->( 'select-quoted-options', qq{s | Pick | required select:"Smith, John",Jones, "A & B" ,<x>\n} );
    $add->( 'select-optional',         "s | Pick | select:One,Two\n" );
    $add->( 'radio-required',          "r | Pick | required radio:Yes,No,Not sure\n" );
    $add->( 'radio-plain',             "r | Pick | radio:A\n" );
    $add->( 'checklist-many-required', "c | Pick | required checklist:Red,Green,Blue\n" );
    $add->( 'checklist-one-required',  "c | I agree | required checklist:Yes\n" );
    $add->( 'checklist-one-optional',  "c | I agree | checklist:Yes\n" );
    $add->( 'checklist-qty',           "c | Order | checklist-qty:Tea,Coffee & cake\n" );
    $add->( 'checklist-qty-required-one', "c | Order | required checklist-qty:Tea\n" );
    $add->( 'select-beats-radio',         "s | Pick | radio:A,B select:C,D\n" );
    $add->( 'textarea-beats-select',      "s | Pick | textarea select:C,D\n" );

    # A whole form: every kind at once, which makes it multipart.
    $add->( 'every-kind',
        "n | Name | required\ne | Email | email\nt | Phone | tel\nf | File | file\nm | Msg | textarea\n"
            . "s | Pick | select:A,B\nr | Radio | radio:A,B\nc | Check | checklist:A,B\nsubmit | Go\n" );

    # The page path and the outcome banner.
    my $body = "name | Name\n";
    my $qs   = sub { { REDIRECT_URL => '/contact', QUERY_STRING => $_[0] } };
    $add->( 'page-path-with-an-ampersand', $body, env => { REDIRECT_URL => '/a&b', QUERY_STRING => '' } );
    $add->( 'page-path-protocol-relative', $body, env => { REDIRECT_URL => '//evil.example/x', QUERY_STRING => '' } );
    $add->( 'page-path-with-markup', $body, env => { REDIRECT_URL => '/a"<b>', QUERY_STRING => '' } );
    $add->( 'page-path-not-absolute', $body, env => { REDIRECT_URL => 'relative/x', QUERY_STRING => '' } );
    $add->( 'page-path-and-query-unset', $body, env => { REDIRECT_URL => undef, QUERY_STRING => undef } );
    $add->( 'outcome-ok',                  $body, env => $qs->('form=w&outcome=ok') );
    $add->( 'outcome-ok-processing-first', $body, env => $qs->('outcome=ok-processing&form=w') );
    $add->( 'outcome-error-encoded', $body, env => $qs->('form=w&outcome=Bad+%3Cscript%3E%22+%26+%5B%25+x+%25%5D') );
    $add->( 'outcome-utf8', $body, env => $qs->('form=w&outcome=Caf%C3%A9+ferm%C3%A9') );
    $add->( 'outcome-not-utf8', $body, env => $qs->('form=w&outcome=%E9t%E9') );
    $add->( 'outcome-too-long', $body, env => $qs->( 'form=w&outcome=' . ( 'x' x 400 ) ) );
    $add->( 'outcome-empty',            $body, env => $qs->('form=w&outcome=') );
    $add->( 'outcome-for-another-form', $body, env => $qs->('form=other&outcome=ok') );
    $add->( 'outcome-form-name-is-a-prefix', $body, env => $qs->('form=ww&outcome=ok') );
    $add->( 'outcome-without-form',          $body, env => $qs->('outcome=ok') );
    $add->( 'outcome-form-name-with-regex-characters', $body,
        meta => { form => 'a.b' }, env => $qs->('form=aXb&outcome=ok') );

    return @c;
}

# --- record, or check ---

if ($WRITE) {
    my @cases = ( written_cases(), corpus_cases() );
    my %ids;
    $ids{ $_->{id} }++ and die "duplicate case id $_->{id}\n" for @cases;
    for my $c (@cases) {
        my $got = run_case($c);
        die "case $c->{id} warned: @{ $got->{warnings} }" if @{ $got->{warnings} };
        delete $got->{warnings};
        $c->{got} = $got;
    }
    open my $fh, '>', $RECORD or die "$RECORD: $!";
    print {$fh} $JSON->encode( { cases => \@cases } );
    close $fh;
    diag( 'recorded ' . scalar(@cases) . " cases to $RECORD" );
}

open my $rh, '<', $RECORD or die "$RECORD: $! (record it: LAZYSITE_CHARACTERISE=write)";
my $record = $JSON->decode( do { local $/; <$rh> } );
close $rh;
my @cases = @{ $record->{cases} };

cmp_ok( scalar @cases, '>=', 100, 'the record holds the corpus and the written cases' );
my %have = map { $_->{id} => 1 } @cases;
for my $branch ( sort keys %BRANCH ) {
    ok( $have{ $BRANCH{$branch} }, "a case reaches $branch ($BRANCH{$branch})" );
}
ok( ( grep { $_->{id} =~ m{\Astarter/contact\.md#1 } } @cases ), 'the shipped contact form is in it' );

for my $c (@cases) {
    my $got = run_case($c);
    my $id  = $c->{id};
    is_deeply( $got->{warnings}, [], "$id: no warning" );
    is( $got->{html}, $c->{got}{html}, "$id: the HTML" );
    is_deeply( $got->{rules}, $c->{got}{rules}, "$id: the rules sidecar" );
    is_deeply( $got->{log},   $c->{got}{log},   "$id: what it logged" );
}

done_testing();
