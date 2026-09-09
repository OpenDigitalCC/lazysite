#!/usr/bin/perl
# SM579 phase 2: the connectors manager page.
#
# Phase 1 shipped connectors API-first, which left the operator who is meant to
# OWN the destination reaching it only through a token client. This is that
# page, and the things asserted here are the ones a lint cannot ask.
#
# The three that matter:
#
#   1. THE CREDENTIAL IS NEVER SHOWN BACK. The API does not return it, and the
#      page must not invent a way to display one - the field is a blank
#      password input that means "replace", never "here is what is set".
#   2. has_secret HAS FOUR STATES (SM784). 1 set, 0 not set, null "the secret
#      store could not be read". Drawing null as "not set" invites an operator
#      to re-enter a credential that is still in place, which is the SM768
#      defect wearing a UI.
#   3. THE CAPABILITY THE NAV GATES ON IS ONE THE PROCESSOR DERIVES. A nav
#      entry gated on a capability absent from the derivation list is invisible
#      to everyone, including its holder. t/lint/83 asks this generally; it is
#      asserted here because this page is the reason the list grew.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                   qw(repo_root);
use Lazysite::Manager::StartPage ();

my $root = repo_root();
my $page = "$root/starter/manager/connectors.md";
ok( -f $page, 'the connectors page is shipped' ) or done_testing, exit;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

# One function's body, from its opening line to the brace in column 0 that
# closes it. WITH A CAPTURE GROUP: the first spelling of this had none, so the
# match returned 1 and every assertion below was made against the string "1" -
# five checks that passed nothing and failed for the wrong reason.
sub body_of {
    my ($name) = @_;
    my ($b)    = $src =~ /(function \Q$name\E\(.*?\n\})/s;
    return $b;
}

subtest 'the page is a manager page the table and the nav agree about' => sub {
    my $p = $Lazysite::Manager::StartPage::PAGES{connectors};
    ok( $p, 'connectors is in the start-page table' ) or return;
    is_deeply( $p->{caps}, ['manage_connectors'],
        'gated on the capability that already gates every connector action' );
    ok( ( grep { $_->{id} eq 'connectors' } Lazysite::Manager::StartPage::manager_pages() ),
        'and it is in the page order, so it can be chosen as a start page' );

    my $proc = do {
        open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $proc, qr/manage_connectors/,
        'the processor derives manage_connectors - a nav gate on a capability '
            . 'it does not derive is an entry nobody can see' );
};

subtest 'the credential is never shown back' => sub {
    like( $src, qr/type="password"/, 'the credential field is a password input' );
    like( $src, qr/leave blank to keep what is there/,
        'and blank means keep, so the page never has to hold the current value' );
    # The list response carries has_secret, never the secret. If the page ever
    # reads a `secret` off a connector it is displaying one.
    unlike( $src, qr/\bc\.secret\b|connector\.secret\b/,
        'the page never reads a secret off a connector it was handed' );
    like( $src, qr/connector-secret-set/,
        'setting one is its own action, apart from the definition' );
};

# SM784. This is the assertion the page exists to satisfy.
subtest 'a credential that cannot be read is not drawn as absent' => sub {
    like( $src, qr/secrets_readable/, 'the page reads the store-readable answer' );
    my $fn = body_of('secretState');
    ok( $fn, 'there is one place that decides how a credential state is shown' )
        or return;
    like( $fn, qr/unknown/, 'and it has an UNKNOWN state' );
    like( $fn, qr/has_secret === null/,
        'null is treated as unknown, not as false' );
    # The three must be visibly different, or the distinction is not made.
    my @labels = $fn =~ /label: '([^']+)'/g;
    is( scalar @labels, 3, 'three distinct labels: set, not set, and cannot tell' )
        or diag("labels: @labels");
    is( scalar( keys %{ { map { $_ => 1 } @labels } } ), 3, 'and none repeats' );
};

subtest 'destroying confirms, and says what goes with it' => sub {
    like( $src, qr/data-impact="destroy"/, 'the delete control declares what it does' );
    my $fn = body_of('deleteConnector');
    ok( $fn, 'the delete path is one function' ) or return;
    like( $fn, qr/mgConfirm/, 'it confirms - the colour is a warning, not the guard' );
    like( $fn, qr/credential is removed with it/,
        'and the confirmation says what else goes, not just "are you sure"' );
    like( $fn, qr/stops working/, 'including what breaks' );
};

subtest 'the page says the boundary that decides the design' => sub {
    like( $src, qr/An author never/,
        'an author never supplies a URL - the whole SSRF answer, stated where '
            . 'the destination is written rather than only in the docs' );
    like( $src, qr/mode that can be abused|MODE THAT CAN BE ABUSED/i,
        'and the public mode says what it is' );
};

# SM806, from the release manager reading the shipped page.
subtest 'the page uses the registered vocabulary and nothing of its own' => sub {
    my @cls   = $src =~ /class="([^"]+)"/g;
    my %used  = map { $_ => 1 } grep { /\Amg-/ } map { split ' ' } @cls;
    my $guide = do {
        open my $fh, '<', "$root/starter/manager/style-guide.md" or die $!;
        local $/;
        <$fh>;
    };
    my @unregistered = grep { $guide !~ /\Q$_\E/ } sort keys %used;
    is_deeply( \@unregistered, [], 'every class on this page is in the style guide' )
        or diag( "not registered: @unregistered\n"
            . 'The guide is the contract; a class it does not name is a page '
            . 'styling itself.' );

    unlike( $src, qr/style="/, 'and no inline style' );

    # It borrowed the permissions editor's own component classes as generic
    # layout. They are registered, so nothing caught it - but mg-perms-* is
    # another page's component, and reusing it is how two idioms become four.
    unlike( $src, qr/mg-perms-/,
        'no component borrowed from another page as generic layout' );
};

subtest 'the row expander is the ONE idiom, not another hand-rolled one' => sub {
    like( $src, qr/class="mg-expand"[^>]*hidden/,
        'the card is hidden with the ATTRIBUTE the stylesheet keys on' );
    like( $src, qr/\.hidden = true/,  'and closed by setting it' );
    like( $src, qr/\.hidden = false/, 'and opened by clearing it' );
    unlike( $src, qr/innerHTML = ''/,
        'not by emptying innerHTML - eight pages rolled their own show/hide '
            . 'and that is the drift the guide exists to end' );
};

# The release manager could not find it, which is the only test that matters
# for a control.
subtest 'a connector can be deleted, and the control is where the eye goes' => sub {
    my ($ed) = $src =~ /(function editorFor\(.*?\n\})/s;
    ok( $ed, 'the editor body was found' ) or return;
    like( $ed, qr/deleteConnector/, 'Delete is in the expander' );
    like( $ed, qr/mg-toolbar.{0,400}mg-btn-danger/s,
        'in the registered control row, beside Save' );
};

subtest 'a value the engine knows is chosen, not typed' => sub {
    like( $src, qr/pickField\(/,    'the table fields are pickers' );
    like( $src, qr/callersField\(/, 'and the caller groups are too' );
    # SM784 again: an empty select is a statement about the site.
    like( $src, qr/var GROUPS = null;/, 'unknown starts as null, not an empty list' );
    like( $src, qr/options === null/,
        'and an unreadable list falls back to a text box rather than showing none' );
    like( $src, qr/not on this site/,
        'a configured value absent from the list is kept and marked, never dropped' );
};

subtest 'the call record is filtered to THIS connector' => sub {
    like( $src, qr/connector-calls&connector=/,
        'the parameter is `connector` - sending `id` did not fail, it just '
            . 'never filtered, so every panel showed every connector history' );
    unlike( $src, qr/connector-calls&id=/, 'and the wrong name is gone' );
};

done_testing;
