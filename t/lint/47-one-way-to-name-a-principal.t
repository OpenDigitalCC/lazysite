#!/usr/bin/perl
# SM305: a principal is named with a <select>, on every manager page.
#
# THE RULE. Naming a person or a group is one piece of functionality, so it gets
# one control. That control is a <select>, because a <select> cannot express a
# principal that does not exist.
#
# WHY THIS IS A TEST. Four pages had grown three different controls for the one
# job - a real <select> on the per-file card, an <input list="..."> datalist on
# Groups and on the add-user form, and a bare text box on the Files section
# sheet. Nothing was wrong with any of them individually, which is exactly why
# they diverged: each was reasonable where it was written, and nobody was
# comparing.
#
# The strictness ran BACKWARDS. The loosest control - the bare text box, which
# offered no suggestions and validated nothing - was the one governing who may
# READ protected content. A mistyped name there granted the section to nobody
# and reported success, which is this repository's recurring defect class: a
# control reporting success without doing the work.
#
# A datalist is not sufficient. It suggests known names and still accepts
# anything typed over it, so it looks constrained and is not. That is worse than
# a plain text box, because it invites the trust it does not earn.
#
# Server-side validation is unaffected either way and stays: this is the
# affordance, not the enforcement.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

# Every manager surface, at any depth - the pages and the shared layout. A glob
# that stopped at one level is what t/lint/46 was written for; do not repeat it.
my @pages;
for my $dir ( "$root/starter/manager", "$root/starter/lazysite/manager" ) {
    next unless -d $dir;
    find(
        {   no_chdir => 1,
            wanted   => sub { push @pages, $_ if /\.(?:md|tt)\z/ && -f $_ },
        },
        $dir
    );
}
@pages = sort @pages;
cmp_ok( scalar @pages, '>=', 8, 'found the manager pages' );

# Datalists that are NOT principal pickers, each with the reason it stays. A
# datalist is the right control for a field that must accept a value the site
# has never seen; it is the wrong one for a field that must not.
#
# Keyed by the datalist id, so adding a NEW datalist requires naming it here and
# saying why - which is the point. An exemption list nobody has to edit stops
# being a decision and becomes a hole.
my %NOT_A_PRINCIPAL = (
    'page-urls' =>
        'SM097: nav URLs. A nav entry may point at an external site, so the '
        . 'field must accept a URL that is not one of this site pages. The '
        . 'datalist suggests the internal ones without forbidding the rest.',
);

subtest 'no manager page names a principal with a datalist' => sub {
    my @offenders;
    for my $p (@pages) {
        my $text = slurp($p);
        ( my $rel = $p ) =~ s{\A\Q$root/\E}{};

        # COMMENTS AND TT COMMENTS STRIPPED. The first cut of this file matched
        # its own explanatory prose in layout.tt - a test reporting a finding it
        # had written itself, which is the t/lint/45 lesson repeated.
        my $code = join "\n", grep { !m{^\s*(?://|\#)} } split /\n/, $text;
        $code =~ s/\[%\#.*?%\]//gs;

        # Both halves of the pattern: the element itself, and an input bound to
        # one. Either alone is the defect - an orphaned <datalist> is dead markup
        # that the next author will wire back up.
        while ( $code =~ /<datalist\b[^>]*\bid\s*=\s*["']([^"']+)["']/gi ) {
            push @offenders, "$rel: <datalist id=\"$1\">"
                unless $NOT_A_PRINCIPAL{$1};
        }
        while ( $code =~ /<input\b[^>]*\blist\s*=\s*["']([^"']+)["']/gi ) {
            push @offenders, "$rel: <input list=\"$1\">"
                unless $NOT_A_PRINCIPAL{$1};
        }
        # A datalist with no id cannot be bound to anything, so it is dead markup
        # whatever it was for.
        push @offenders, "$rel: <datalist> with no id"
            if $code =~ /<datalist\b(?![^>]*\bid\s*=)/i;
    }

    is_deeply( \@offenders, [], 'principals are named with a <select>' )
        or diag( join "\n  ",
        '',
        @offenders,
        '',
        'A datalist suggests known names and still accepts anything typed over',
        'it, so it looks constrained and is not. Use mgPrincipalSelect() from',
        'the shared manager layout, which builds a <select> from one source.' );
};

subtest 'the shared picker exists and is the one implementation' => sub {
    my $layout = "$root/starter/lazysite/manager/layout.tt";
    ok( -f $layout, 'the shared manager layout is present' ) or return;
    my $text = slurp($layout);

    for my $fn (qw(mgSetPrincipals mgPrincipalOptions mgPrincipalSelect mgIsPrincipal)) {
        like( $text, qr/\bwindow\.\Q$fn\E\s*=/,
            "the layout defines $fn for every page to use" );
    }

    # The guard on the guard: a page may only build principal <option> markup by
    # going through the shared helper. A page that assembles its own option list
    # has re-forked the thing this file exists to keep singular - which is how
    # the four controls arose in the first place.
    my @rolled_their_own;
    for my $p (@pages) {
        next if $p eq $layout;
        my $body = slurp($p);
        ( my $rel = $p ) =~ s{\A\Q$root/\E}{};

        # A principal option list is recognisable: it maps a users or groups
        # collection straight into <option> markup.
        push @rolled_their_own, $rel
            if $body =~ /(?:users|groups|PRINCIPALS)[^\n]{0,80}<option value=/i
            && $body !~ /mgPrincipalOptions|mgPrincipalSelect/;
    }

    is_deeply( \@rolled_their_own, [],
        'no page builds its own principal option list' )
        or diag( join "\n  ",
        '',
        @rolled_their_own,
        '',
        'Call mgPrincipalOptions() or mgPrincipalSelect() instead. One list,',
        'one sort order, one set of rules about what may be named.' );
};

done_testing();
