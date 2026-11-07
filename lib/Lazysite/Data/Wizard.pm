package Lazysite::Data::Wizard;

# SM1355 (ruling 156): A WIZARD BUILDS OR EDITS ONE ROW, ONE QUESTION AT A TIME.
#
# An owner builds their list of items once - a menu, a price list, a service
# list - by answering questions rather than filling a form of columns. A wizard
# definition is a file, lazysite/db/wizards/<name>.yaml, naming a data table and
# one question per step:
#
#     title: Add a dish
#     table: menu
#     steps:
#       - field: name
#         ask: What is the dish called?
#         type: text
#         required: true
#         help: As it should appear on the menu.
#       - field: price
#         ask: How much is it?
#         type: price
#         required: true
#       - field: spicy
#         ask: Is it spicy?
#         type: yesno
#       - field: heat
#         ask: How hot?
#         type: choice
#         options: [mild, medium, hot]
#         when: { field: spicy, is: true }
#
# THE TYPES and the field each writes:
#
#   text     a text field
#   price    a decimal field; a currency sign and thousands commas are taken off
#   choice   an enum field (its values, or a subset in `options`), or a text
#            field with `options`
#   choices  a text field with `options`; the chosen ones are stored joined by
#            commas, in the order the options are listed
#   yesno    a boolean field
#
# CHECKED AGAINST THE TABLE AT LOAD, refused by step and rule: a field the table
# does not declare, the table's key when the store assigns it, a type the field
# cannot hold, a `when` naming a step that does not come earlier. A field the
# table requires (with no default) must be asked, by a required step with no
# `when` - required facts are always asked, never guessed, and a wizard that
# could skip one would build a row the table refuses.
#
# RUNNING IS STATELESS: the caller sends the answers so far, and the answer is
# the next question, or `complete` with the row. An answer of null (or "") to an
# optional step skips it; to a required step it is refused and the step asked
# again - a required question cannot be skipped. A step whose `when` is not met
# is not asked, and an answer sent for it is left out and named. The row is
# written by the caller (Manager::Data::action_data_wizard_run), through the
# same row save every other door uses, recorded as from `wizard:<name>`.
#
# Pure apart from reading the definition files: no store, no writes.

use strict;
use warnings;
use utf8;    # the currency signs a price answer may carry
use Exporter 'import';
use JSON::PP        ();
use Lazysite::Paths ();

our @EXPORT_OK = qw(wizard_dir load_wizard list_wizards check_definition run_steps);

our %TYPE_FIELD = (
    text    => [qw(text)],
    price   => [qw(decimal)],
    choice  => [qw(enum text)],
    choices => [qw(text)],
    yesno   => [qw(boolean)],
);
my $MAX_STEPS = 50;

sub _err {
    my ( $msg, %x ) = @_;
    return { ok => 0, kind => 'wizard', error => $msg, %x };
}

sub wizard_dir { return Lazysite::Paths::lazysite_dir( $_[0] ) . '/db/wizards' }

sub valid_name { return ( defined $_[0] && $_[0] =~ /\A[a-z][a-z0-9_]{0,63}\z/ ) ? 1 : 0 }

# The definition, read from its file and checked against its table.
sub load_wizard {
    my ( $docroot, $name ) = @_;
    return _err( "'" . ( $name // '' ) . "' is not a wizard name (lower-case letters, digits, _)",
        rule => 'name' )
        unless valid_name($name);
    my $file = wizard_dir($docroot) . "/$name.yaml";
    return _err( "no wizard '$name' is defined", kind => 'no_such_wizard', wizard => $name )
        unless -f $file;
    return _err( 'the YAML::PP module is not installed, so a wizard cannot be read',
        kind => 'missing_module', module => 'YAML::PP' )
        unless eval { require YAML::PP; 1 };
    my $raw = eval { YAML::PP->new->load_file($file) };
    return _err( "wizard '$name': not valid YAML - " . ( $@ =~ s/\s+\z//r ), wizard => $name )
        if $@ || !defined $raw;
    require Lazysite::Data::Tables;
    return check_definition( $name, $raw,
        sub { Lazysite::Data::Tables::load_table( $docroot, $_[0] ) } );
}

sub list_wizards {
    my ($docroot) = @_;
    my $dir = wizard_dir($docroot);
    my @out;
    opendir my $dh, $dir or return { ok => 1, wizards => [] };
    my @names = sort map { /\A([a-z][a-z0-9_]{0,63})\.yaml\z/ ? $1 : () } readdir $dh;
    closedir $dh;
    for my $n (@names) {
        my $w = load_wizard( $docroot, $n );
        push @out, $w->{ok}
            ? { name => $n, title => $w->{title}, table => $w->{table}, steps => scalar @{ $w->{steps} } }
            : { name => $n, ok => JSON::PP::false(), error => $w->{error} };
    }
    return { ok => 1, wizards => \@out };
}

# THE CHECK, against the table's loaded descriptor ($table_loader->(name)).
sub check_definition {
    my ( $name, $raw, $table_loader ) = @_;
    return _err( "wizard '$name': a definition is a mapping (title, table, steps)", wizard => $name )
        unless ref $raw eq 'HASH';
    my %known = map { $_ => 1 } qw(title table steps help);
    for my $k ( sort keys %$raw ) {
        return _err( "wizard '$name': '$k' is not a wizard key (title, table, steps, help)",
            wizard => $name, rule => 'unknown_key' )
            unless $known{$k};
    }
    my $tname = $raw->{table};
    return _err( "wizard '$name': `table` names the data table the wizard writes",
        wizard => $name, rule => 'table' )
        unless defined $tname && !ref $tname && length $tname;
    my $d = $table_loader->($tname);
    return _err( "wizard '$name': its table '$tname' does not load - " . ( $d->{error} // 'unknown' ),
        wizard => $name, rule => 'table' )
        unless ref $d eq 'HASH' && $d->{ok};
    my $steps = $raw->{steps};
    return _err( "wizard '$name': `steps` is a list of questions, one per step",
        wizard => $name, rule => 'steps' )
        unless ref $steps eq 'ARRAY' && @$steps;
    return _err( "wizard '$name': at most $MAX_STEPS steps", wizard => $name, rule => 'steps' )
        if @$steps > $MAX_STEPS;

    my ( @out, %seen );
    my %step_keys = map { $_ => 1 } qw(field ask type required help options when);
    for my $i ( 0 .. $#$steps ) {
        my $s = $steps->[$i];
        my $n = $i + 1;
        my $bad = sub { _err( "wizard '$name' step $n: $_[0]", wizard => $name, step => $n, rule => $_[1] ) };
        return $bad->( 'a step is a mapping (field, ask, type, ...)', 'step' ) unless ref $s eq 'HASH';
        for my $k ( sort keys %$s ) {
            return $bad->( "'$k' is not a step key (field, ask, type, required, help, options, when)",
                'unknown_key' )
                unless $step_keys{$k};
        }
        my $f = $s->{field};
        return $bad->( '`field` names the table field this step writes', 'field' )
            unless defined $f && !ref $f && length $f;
        return $bad->( "'$f' is the key '$tname' assigns itself - it is never asked", 'auto_key' )
            if $d->{auto_key} && $f eq $d->{key};
        my $spec = $d->{fields}{$f};
        return $bad->( "'$f' is not a field of '$tname'", 'field' ) unless ref $spec eq 'HASH';
        return $bad->( "'$f' is asked by step $seen{$f} already", 'field' ) if $seen{$f};
        $seen{$f} = $n;

        my $type = $s->{type} // '';
        my $fits = $TYPE_FIELD{$type}
            or return $bad->( "'$type' is not a step type (text, price, choice, choices, yesno)", 'type' );
        my $ftype = $spec->{type} // '';
        return $bad->( "a $type step cannot write '$f', a $ftype field ("
                . join( ' or ', @$fits ) . ' needed)', 'type' )
            unless grep { $_ eq $ftype } @$fits;

        my $ask = $s->{ask};
        return $bad->( '`ask` is the question, in words', 'ask' )
            unless defined $ask && !ref $ask && $ask =~ /\S/;
        my $help = $s->{help};
        return $bad->( '`help` is a sentence of text', 'help' ) if defined $help && ref $help;

        my @options;
        if ( $type eq 'choice' || $type eq 'choices' ) {
            my $given = $s->{options};
            return $bad->( '`options` is a list of the answers it offers', 'options' )
                if defined $given && ref $given ne 'ARRAY';
            if ( $ftype eq 'enum' ) {
                my %v = map { $_ => 1 } @{ $spec->{values} || [] };
                @options = $given ? @$given : @{ $spec->{values} || [] };
                for my $o (@options) {
                    return $bad->( "'$o' is not one of '$f''s values", 'options' ) unless $v{$o};
                }
            }
            else {
                return $bad->( "a $type step on a text field lists its `options`", 'options' )
                    unless $given && @$given;
                @options = @$given;
            }
            my %dup;
            for my $o (@options) {
                return $bad->( 'an option is a word or phrase, not a list or mapping', 'options' )
                    if !defined $o || ref $o || !length $o;
                return $bad->( "the option '$o' is listed twice", 'options' ) if $dup{$o}++;
                return $bad->( "the option '$o' holds a comma, which separates the choices stored",
                    'options' )
                    if $type eq 'choices' && $o =~ /,/;
            }
        }
        elsif ( defined $s->{options} ) {
            return $bad->( "`options` belong to a choice or choices step, not a $type step", 'options' );
        }

        my $required = _truthy( $s->{required} );
        return $bad->( '`required` is true or false', 'required' )
            if defined $s->{required} && !defined $required;
        $required //= 0;

        my $when;
        if ( defined $s->{when} ) {
            my $w = $s->{when};
            return $bad->( '`when` is a mapping: { field: <an earlier step\'s field>, is: <answer or list> }',
                'when' )
                unless ref $w eq 'HASH' && defined $w->{field} && exists $w->{is}
                && !grep { $_ ne 'field' && $_ ne 'is' } keys %$w;
            my $on = $seen{ $w->{field} };
            return $bad->( "`when` names '$w->{field}', which no earlier step asks", 'when' )
                unless $on && $on < $n;
            my @is = ref $w->{is} eq 'ARRAY' ? @{ $w->{is} } : ( $w->{is} );
            return $bad->( '`when`\'s `is` is an answer or a list of answers', 'when' )
                if !@is || grep { ref $_ && ref $_ ne 'JSON::PP::Boolean' } @is;
            $when = { field => $w->{field}, is => [ map { _scalar($_) } @is ] };
        }

        # REQUIRED FACTS ARE ALWAYS ASKED. A field the table requires is a
        # required step that is always asked.
        my $table_requires = $spec->{required} && !defined $spec->{default};
        return $bad->( "'$f' is required by '$tname', so its step is required too", 'required' )
            if $table_requires && !$required;
        return $bad->( "'$f' is required by '$tname', so its step is always asked (no `when`)", 'when' )
            if $table_requires && $when;

        push @out, {
            index    => $n, field => $f, ask => $ask, type => $type,
            required => $required ? 1 : 0,
            ( defined $help ? ( help    => $help )                     : () ),
            ( @options      ? ( options => [ map { "$_" } @options ] ) : () ),
            ( $when         ? ( when    => $when )                     : () ),
        };
    }

    # Every field the table requires is asked (the key included, unless the
    # store assigns it).
    for my $f ( sort keys %{ $d->{fields} } ) {
        my $spec = $d->{fields}{$f};
        next unless $spec->{required} && !defined $spec->{default};
        return _err( "wizard '$name': '$tname' requires '$f', and no step asks it - "
                . 'required facts are asked, never guessed',
            wizard => $name, field => $f, rule => 'required_unasked' )
            unless $seen{$f};
    }
    if ( !$d->{auto_key} && !$seen{ $d->{key} } ) {
        return _err( "wizard '$name': '$tname' is keyed by '$d->{key}', which no step asks - "
                . 'a new row needs its key', wizard => $name, field => $d->{key}, rule => 'required_unasked' );
    }

    my $title = $raw->{title};
    return {
        ok    => 1,
        name  => $name,
        title => ( defined $title && !ref $title && length $title ) ? $title : $name,
        table => $tname,
        key   => $d->{key},
        steps => \@out,
        ( defined $raw->{help} && !ref $raw->{help} ? ( help => $raw->{help} ) : () ),
    };
}

sub _truthy {
    my ($v) = @_;
    return undef unless defined $v;
    return $v ? 1 : 0 if ref $v eq 'JSON::PP::Boolean';
    return undef      if ref $v;
    return 1          if $v =~ /\A(?:1|true|yes)\z/i;
    return 0          if $v =~ /\A(?:0|false|no|)\z/i;
    return undef;
}

sub _scalar {
    my ($v) = @_;
    return ( $v ? 1 : 0 ) if ref $v eq 'JSON::PP::Boolean';
    return $v;
}

# One answer, made the value its field stores. Returns ( $err ) or ( undef, $value ).
sub _answer_value {
    my ( $step, $v ) = @_;
    my $t = $step->{type};
    if ( $t eq 'choices' ) {
        my @picked
            = ref $v eq 'ARRAY' ? @$v
            : ( !ref $v ) ? ( grep { length } map { s/\A\s+|\s+\z//gr } split /,/, $v )
            :               return ('is a list of its options');
        my %pick;
        for my $p (@picked) {
            return ('is a list of its options') if ref $p;
            return ( "is one of its options (" . join( ', ', @{ $step->{options} } ) . "), not '$p'" )
                unless grep { $_ eq $p } @{ $step->{options} };
            $pick{$p} = 1;
        }
        return ( undef, join ',', grep { $pick{$_} } @{ $step->{options} } );
    }
    return ('is one answer, not a list or mapping') if ref $v && ref $v ne 'JSON::PP::Boolean';
    if ( $t eq 'yesno' ) {
        my $b = _truthy($v);
        return ('is yes or no') unless defined $b;
        return ( undef, $b );
    }
    if ( $t eq 'choice' ) {
        return ( "is one of its options (" . join( ', ', @{ $step->{options} } ) . "), not '$v'" )
            unless grep { $_ eq $v } @{ $step->{options} };
        return ( undef, "$v" );
    }
    if ( $t eq 'price' ) {
        ( my $p = "$v" ) =~ s/\A\s+|\s+\z//g;
        $p               =~ s/\A(-?)\s*[£\$€]\s*/$1/;
        $p               =~ s/(?<=\d),(?=\d{3}(?:\D|\z))//g;
        return ("is an amount, such as 4.50, not '$v'") unless $p =~ /\A-?\d+(?:\.\d+)?\z/;
        return ( undef, $p );
    }
    return ( undef, "$v" );    # text
}

sub _empty { my ($v) = @_; return !defined $v || ( !ref $v && $v =~ /\A\s*\z/ ) || ( ref $v eq 'ARRAY' && !@$v ) }

# Walk the steps with the answers so far. $current is the row being edited
# (undef for a new one): its key step is not asked, and each question shows the
# value it holds. Returns the next question, or the complete row.
sub run_steps {
    my ( $w, $answers, $current ) = @_;
    $answers = {} unless defined $answers;
    return _err( 'answers are a mapping of field to answer', rule => 'answers' )
        unless ref $answers eq 'HASH';
    my %by_field = map { $_->{field} => $_ } @{ $w->{steps} };
    for my $f ( sort keys %$answers ) {
        return _err( "'$f' is not a question of wizard '$w->{name}'", field => $f, rule => 'answers' )
            unless $by_field{$f};
    }

    my ( %row, @skipped, @not_asked, @answered );
    my $editing = ref $current eq 'HASH';
    my $total   = 0;
    for my $s ( @{ $w->{steps} } ) {
        my $f = $s->{field};
        next if $editing && $f eq $w->{key};    # a row's address is not edited
        if ( my $c = $s->{when} ) {
            my $have = $row{ $c->{field} };
            my $met  = 0;
            if ( defined $have ) {
                my %got = map { $_ => 1 } ( $by_field{ $c->{field} }{type} eq 'choices' ? split /,/, $have : ($have) );
                $met = grep { $got{ _norm_is( $by_field{ $c->{field} }, $_ ) } } @{ $c->{is} };
            }
            unless ($met) {
                push @not_asked, $f if exists $answers->{$f};
                next;
            }
        }
        $total++;
        unless ( exists $answers->{$f} ) {
            return {
                ok       => 1,
                complete => JSON::PP::false(),
                wizard   => $w->{name},
                question => _question( $s, $current ),
                progress => { step => scalar(@answered) + scalar(@skipped) + 1 },
                answers  => \%row,
                ( @not_asked ? ( not_asked => \@not_asked ) : () ),
            };
        }
        my $v = $answers->{$f};
        if ( _empty($v) ) {
            if ( $s->{required} ) {
                return {
                    ok     => 0,
                    kind   => 'required',
                    wizard => $w->{name},
                    field  => $f,
                    error => "'$s->{ask}' is required and cannot be skipped - answer it to go on",
                    question => _question( $s, $current ),
                };
            }
            push @skipped, $f;
            next;
        }
        my ( $why, $val ) = _answer_value( $s, $v );
        if ( defined $why ) {
            return {
                ok       => 0,
                kind     => 'answer',
                wizard   => $w->{name},
                field    => $f,
                error    => "The answer to '$s->{ask}' $why.",
                question => _question( $s, $current ),
            };
        }
        $row{$f} = $val;
        push @answered, $f;
    }
    return {
        ok       => 1,
        complete => JSON::PP::true(),
        wizard   => $w->{name},
        table    => $w->{table},
        row      => \%row,
        skipped  => \@skipped,
        ( @not_asked ? ( not_asked => \@not_asked ) : () ),
        steps_asked => $total,
    };
}

sub _norm_is {
    my ( $step, $v ) = @_;
    return $v unless $step->{type} eq 'yesno';
    my $b = _truthy($v);
    return defined $b ? $b : $v;
}

sub _question {
    my ( $s, $current ) = @_;
    my %q = map { $_ => $s->{$_} } grep { exists $s->{$_} } qw(index field ask type help options);
    $q{required} = $s->{required} ? JSON::PP::true() : JSON::PP::false();
    if ( ref $current eq 'HASH' && exists $current->{ $s->{field} } ) {
        my $c = $current->{ $s->{field} };
        $c = [ grep { length } split /,/, $c ] if $s->{type} eq 'choices' && defined $c;
        $c = ( $c ? JSON::PP::true() : JSON::PP::false() ) if $s->{type} eq 'yesno' && defined $c;
        $q{current} = $c;
    }
    return \%q;
}

1;
