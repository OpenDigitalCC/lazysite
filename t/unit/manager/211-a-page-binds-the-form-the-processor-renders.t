#!/usr/bin/perl
# SM976 Q15f (ruled 2026-10-09, "One reading, processor's"): the form rule reads
# which form a page binds as the processor renders it.
#
# Until Q15f the walker behind the form rule (form_bindings) read the first plain
# `form: NAME` line within the first 16 KB, while the processor renders the form
# its own front-matter parse finds. Measured (tmp/q15e-walker-probe.out): a page
# in another domain with `form:` and the name on the next line rendered and
# received the form `contact`, and the walker did not see it, so a caller scoped
# to a domain that also bound `contact` reached the other site's submissions.
#
# EVERY CASE WHERE THE ANSWER CHANGED, each asserted below on a caller scoped to
# sites/mine (the instance has mine.test at sites/mine and other.test at
# sites/other). Narrows - a page in another domain the walker missed now binds
# there, so the form stops being the caller's:
#   N1 the name on the next line (the probe's case)
# Widens inside scope - a page of the caller's own the walker missed now binds
# there, so a form bound nowhere else becomes the caller's:
#   W1 a second form: line (the last renders)       W4 a TT marker in the value
#   W2 a name the sanitiser completes (a dot)       W5 front matter past 16 KB
#   W3 a trailing comment (its words join the name) W6 a no-break space on a fence
# Narrows inside scope - a page of the caller's the walker counted, on which the
# processor renders no form (or another one), no longer makes the form its own:
#   R1 the first of two form: lines                  R4 an empty value swallowing it
#   R2 a later form: '' (the last wins, and is none) R5 a non-ASCII key swallowing it
#   R3 the closing fence with no newline after it
# The validator and the audit read the same way (V1).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common  qw(form_bindings caller_may_reach_form page_form);
use Lazysite::Manager::Domains ();
use Lazysite::Validate         ();

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/forms", "$d/sites/mine", "$d/sites/other" );
{
    open my $cf, q(>), "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nalias_hosts: mine.test, other.test\n"
        . "alias.mine.test.content_root: sites/mine\nalias.other.test.content_root: sites/other\n";
    close $cf;
}
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT = $d;

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>:utf8', "$d/$p" or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
my @MINE = ( scopes => ['sites/mine'] );
sub reaches { return caller_may_reach_form( $_[0], @MINE ) ? 'reaches' : 'refused' }

# N1, the probe: contact bound canonically in mine, and in other with the name on
# the next line.
spit( 'sites/mine/contact.md',  "---\nform: contact\n---\n" );
spit( 'sites/other/contact.md', "---\ntitle: Contact\nform:\n  contact\n---\n" );

# W1-W6: a form on a page in mine only, in a shape the walker missed.
spit( 'sites/mine/w1.md', "---\nform: w1decoy\nform: w1\n---\n" );
spit( 'sites/mine/w2.md', "---\nform: w.2\n---\n" );
spit( 'sites/mine/w3.md', "---\nform: w3 # x\n---\n" );
spit( 'sites/mine/w4.md', "---\nform: [% '' %]w4\n---\n" );
spit( 'sites/mine/w5.md', "---\n" . ( "pad: " . ( 'y' x 80 ) . "\n" ) x 250 . "form: w5\n---\n" );
spit( 'sites/mine/w6.md', "---\x{A0}\nform: w6\n---\n" );

# R1-R5: a page in mine the walker counted as binding the form, on which the
# processor renders none of it.
spit( 'sites/mine/r1.md', "---\nform: r1\nform: r1other\n---\n" );
spit( 'sites/mine/r2.md', "---\nform: r2\nform: ''\n---\n" );
spit( 'sites/mine/r3.md', "---\nform: r3\n---" );
spit( 'sites/mine/r4.md', "---\ntitle:\nform: r4\n---\n" );
spit( 'sites/mine/r5.md', "---\nn\x{E9}:\nform: r5\n---\n" );

my $b    = form_bindings();
my %CASE = (
   #  form       bound on (form_bindings)                       scoped-to-mine  was (n316)
    contact => [ [ 'sites/mine/contact.md', 'sites/other/contact.md' ], 'refused', 'reaches', 'N1' ],
    w1      => [ ['sites/mine/w1.md'], 'reaches', 'refused', 'W1' ],
    w1decoy => [ [],                   'refused', 'reaches', 'W1 (the first line)' ],
    w2      => [ ['sites/mine/w2.md'], 'reaches', 'refused', 'W2' ],
    w3x     => [ ['sites/mine/w3.md'], 'reaches', 'refused', 'W3' ],
    w3      => [ [],                   'refused', 'refused', 'W3 (the name as typed)' ],
    w4      => [ ['sites/mine/w4.md'], 'reaches', 'refused', 'W4' ],
    w5      => [ ['sites/mine/w5.md'], 'reaches', 'refused', 'W5' ],
    w6      => [ ['sites/mine/w6.md'], 'reaches', 'refused', 'W6' ],
    r1      => [ [],                   'refused', 'reaches', 'R1' ],
    r1other => [ ['sites/mine/r1.md'], 'reaches', 'refused', 'R1 (the last line)' ],
    r2      => [ [],                   'refused', 'reaches', 'R2' ],
    r3      => [ [],                   'refused', 'reaches', 'R3' ],
    r4      => [ [],                   'refused', 'reaches', 'R4' ],
    r5      => [ [],                   'refused', 'reaches', 'R5' ],
);
for my $f ( sort keys %CASE ) {
    my ( $pages, $now, $was, $label ) = @{ $CASE{$f} };
    is_deeply( $b->{$f} || [], $pages, "$label: '$f' is bound where the processor renders it" );
    is( reaches($f), $now, "$label: a caller scoped to sites/mine - $now (n316: $was)" );
}

subtest 'unchanged: the canonical shapes' => sub {
    spit( 'sites/mine/plain.md',   "---\nform: plain\n---\n" );
    spit( 'sites/other/theirs.md', "---\nform: 'theirs'\n---\n" );
    my $b2 = form_bindings();
    is_deeply( $b2->{plain},  ['sites/mine/plain.md'],   'a plain form: line binds' );
    is_deeply( $b2->{theirs}, ['sites/other/theirs.md'], 'a quoted one too' );
    is( reaches('plain'),  'reaches', 'the caller reaches its own' );
    is( reaches('theirs'), 'refused', 'and not the other domain\'s' );
    ok( caller_may_reach_form( 'contact', scopes => [] ), 'an unbound grant reaches every form (R3)' );
};

subtest 'V1: the validator reads the form the page renders' => sub {
    my $page = "---\ntitle: T\nform:\n  leads\n---\n\n:::form\nn | N\n:::\n";
    is( page_form($page), 'leads', 'the page binds leads' );
    my $v = Lazysite::Validate::validate_content( content => $page, docroot => $d, path => '/x.md' );
    my %kinds = map { $_->{kind} => $_->{message} } @{ $v->{warnings} || [] };
    ok( !exists $kinds{'form-unnamed'}, 'not called unnamed' );
    like( $kinds{'form-unbound'} // '', qr/'leads'/, 'and named by the form it renders' );
};

done_testing();
