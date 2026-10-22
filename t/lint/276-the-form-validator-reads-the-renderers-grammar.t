#!/usr/bin/perl
# SM1253: THE FORM VALIDATOR READS A FIELD'S RULES AS THE RENDERER DOES.
#
# Lazysite::Validate::_check_form_rules (validate_page, `lazysite validate`,
# the manager's page check) reported rules the renderer accepts as unknown:
# radio and checklist options with a space in them, a quoted
# `placeholder:"Your full name"`, and the `file` and `multiple` rules (reported
# from the lazysite.io design kit, 2026-10-22, K-2). `invalid-form-rule` is an
# ISSUE, so a valid form failed the page.
#
# The validator cannot load the processor (ADR 0001), so its cut of the rules
# is a MARKED COPY of the renderer's, and this is the pin. Asserted by RUNNING
# BOTH, never by comparing source, as t/lint/219 and 220 do:
#
#   1. Every rule word the renderer accepts. The candidates are every word in
#      forms.pm - each rule name is a literal there - tried bare and with a
#      value; the RENDERER says which it takes (_form_rules_from_tokens sets a
#      rule from it). The validator must pass every one it takes, and flag
#      every bare word it does not, so a rule added to one side alone fails
#      here whichever side it was.
#   2. The cut. Every `:::form` line in starter/, docs/, website/ and t/, the
#      written cases, and a seeded generator of rule strings from the fragments
#      a tokeniser gets wrong: both produce the same tokens.
#   3. The reported cases, through validate_content end to end.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Find qw(find);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir repo_root);
use Lazysite::Validate ();

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

my $ROOT = repo_root();

# The renderer logs an unclosed quoted value; nothing here wants the log.
no warnings qw(redefine once);
local *main::log_event = sub { return };

sub renderer_takes {
    my ($tok) = @_;
    my %r = main::_form_rules_from_tokens($tok);
    return %r ? 1 : 0;
}

sub validator_flags {
    my ($rules) = @_;
    my $page = "---\ntitle: T\nform: f\n---\n\n::: form\nx | X | $rules\nsubmit | Send\n:::\n";
    my $r = Lazysite::Validate::validate_content( content => $page );
    return scalar grep { $_->{kind} eq 'invalid-form-rule' } @{ $r->{issues} };
}

# --- 1. every rule the renderer accepts ----------------------------------------
{
    open my $fh, '<', "$ROOT/lazysite-processor/forms.pm" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my %word = map { $_ => 1 } $src =~ /\b([a-z][a-z-]*[a-z])\b/g;
    cmp_ok( scalar keys %word, '>', 200, 'the candidate words were read from the renderer' );

    my ( @bare, @valued );
    for my $w ( sort keys %word ) {
        push @bare, $w if renderer_takes($w);
        for my $v ( 'x', '1', 'user', 'a,b' ) {
            push @valued, "$w:$v" if renderer_takes("$w:$v");
        }
    }

    # A floor, so a renderer that stopped reading rules does not pass by
    # accepting nothing. These are the ones the report named, and the old ten.
    my %b = map { $_ => 1 } @bare;
    for my $must (qw(required optional email tel date time number url password textarea file multiple capture)) {
        ok( $b{$must}, "the renderer takes the bare rule '$must'" );
    }
    my %v = map { ( $_ =~ /\A([a-z-]+):/ )[0] => 1 } @valued;
    for my $must (qw(accept capture select radio checklist checklist-qty max min pattern placeholder value prefill)) {
        ok( $v{$must}, "the renderer takes the valued rule '$must:'" );
    }

    my @wrong = grep { validator_flags($_) } @bare, @valued;
    is_deeply( \@wrong, [], 'the validator passes every rule the renderer takes (' . ( @bare + @valued ) . ')' )
        or diag("flagged: @wrong");

    my @missed = grep { /\A[a-z]+\z/ && !$b{$_} && !validator_flags($_) } sort keys %word;
    is_deeply( \@missed, [], 'and flags every bare word the renderer ignores' )
        or diag("passed but ignored by the renderer: @missed");

    # SM1264: a key:value the renderer does not read is a WARNING - so the
    # validator's reading of a valued rule must be the renderer's, both ways,
    # for every word in forms.pm with every shape of value.
    my @disagree;
    for my $w ( sort keys %word ) {
        for my $v ( 'x', '1', '12', 'user', 'environment', 'front', 'a,b', 'a b', '' ) {
            my $tok = "$w:$v";
            push @disagree, $tok
                if renderer_takes($tok) != Lazysite::Validate::form_value_rule_known($tok);
        }
    }
    is_deeply( \@disagree, [], 'the validator reads a key:value rule as the renderer does, token by token' )
        or diag("disagree: @disagree[0 .. ($#disagree < 9 ? $#disagree : 9)]");
}

# --- 2. the same cut ------------------------------------------------------------
sub corpus_lines {
    my @files;
    find( sub { push @files, $File::Find::name if -f && /\.(?:md|t)\z/ }, map {"$ROOT/$_"} qw(starter docs website t) );
    my @lines;
    for my $f ( sort @files ) {
        open my $fh, '<', $f or die "$f: $!";
        my $text = do { local $/; <$fh> };
        close $fh;
        while ( $text =~ /^:::[ \t]*form[ \t]*\n(.*?)^:::[ \t]*\n/gsm ) {
            for my $line ( split /\n/, $1 ) {
                $line =~ s/^\s+|\s+$//g;
                my ( undef, undef, $rules ) = split /\s*\|\s*/, $line, 3;
                push @lines, $rules if defined $rules && length $rules;
            }
        }
    }
    return @lines;
}

my @written = (
    'required radio:Yes please,No thanks',
    'checklist:Red wine,White wine,Rose',
    'checklist-qty:Small box,Large box required',
    'select:"A one","B two"',
    'placeholder:"Your full name" required max:200',
    'value:"before \" after" required',
    'value:"ends in a backslash\\" max:5',
    'placeholder:"never closed required',
    'pattern:[0-9 ()+.-]{6,30}',
    'pattern:"[a-z ]+" required',
    'pattern:"a\"b" required',
    'file accept:image/* multiple capture:environment required',
    'capture required',
    'textarea   max:5000   ',
    'tel pattern:\d{3} \d{4}',
    'required select:a,b pattern:x',
    '',
);

my @lines = ( corpus_lines(), @written );
cmp_ok( scalar @lines, '>', 50, 'the corpus was read (' . scalar(@lines) . ' rule strings)' );

srand 1253;
my @frag = ( 'required', ' ', '  ', 'placeholder:"a b"', 'value:"x \" y"', 'max:5', 'radio:a b,c',
    'pattern:"p q"', 'pattern:[a ]', '"', '\\', 'select:', 'file', 'label:"', 'x:"', 'min:1', "\t" );
for ( 1 .. 2000 ) {
    push @lines, join '', map { $frag[ int rand @frag ] } 1 .. 1 + int rand 6;
}

my @differ;
for my $rules (@lines) {
    my @r = main::_form_rule_tokens( $rules, 'f' );
    my @v = Lazysite::Validate::form_rule_tokens($rules);
    push @differ, $rules unless join( "\0", @r ) eq join( "\0", @v ) && @r == @v;
}
is_deeply( \@differ, [], 'the validator cuts every rule string as the renderer does (' . scalar(@lines) . ')' )
    or diag( 'first: ' . join ' | ', @differ[ 0 .. ( $#differ < 4 ? $#differ : 4 ) ] );

# --- 3. the reported cases, end to end ------------------------------------------
for my $ok (
    'required radio:Yes please,No thanks',
    'checklist:Red wine,White wine',
    'placeholder:"Your full name" required',
    'file accept:image/* multiple',
    'file capture',
    )
{
    is( validator_flags($ok), 0, "valid and passed: $ok" );
}
is( validator_flags('requird email'), 1, 'a real typo is still an issue' );
is( validator_flags('placeholder:"x y" requird'), 1, 'and after a quoted value too' );

done_testing();
