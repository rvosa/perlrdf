# RDF::Trine::Model::StatementFilter
# -------------
# $Revision: 121 $
# $Date: 2006-02-06 23:07:43 -0500 (Mon, 06 Feb 2006) $
# -----------------------------------------------------------------------------

=head1 NAME

RDF::Trine::Model::StatementFilter - Model for filtering statements based on a user-specified criteria

=head1 METHODS

=over 4

=cut

package RDF::Trine::Model::StatementFilter;

use strict;
use warnings;
use Data::Dumper;
use base qw(RDF::Trine::Model);
use Scalar::Util qw(blessed reftype);

use RDF::Trine::Node;
use RDF::Trine::Pattern;
use RDF::Trine::Store::DBI;
use RDF::Trine::Iterator qw(sgrep);

our $debug;
BEGIN {
	$debug	= 0;
}

################################################################################

=item C<< new ( $store ) >>

Returns a new statement-filter model.

=cut

sub new {
	my $class		= shift;
	my $self		= $class->SUPER::new( @_ );
	$self->{rules}	= [];
	return $self;
}

=item C<< count_statements ($subject, $predicate, $object) >>

Returns a count of all the statements matching the specified subject,
predicate and objects. Any of the arguments may be undef to match any value.

=cut

sub count_statements {
	my $self	= shift;
	my $s		= shift;
	my $p		= shift;
	my $o		= shift;
	my $st		= RDF::Trine::Statement->new( $s, $p, $o );
	
	my $count	= 0;
	my $i		= $self->get_statements( $s, $p, $o );
	while (my $s = $i->next) {
		$count++;
	}
	return $count;
}

=item C<< get_statements ($subject, $predicate, $object [, $context] ) >>

Returns a stream object of all statements matching the specified subject,
predicate and objects from all of the rdf stores. Any of the arguments may be
undef to match any value.

=cut

sub get_statements {
	my $self	= shift;
	my $s		= shift;
	my $p		= shift;
	my $o		= shift;
	my $c		= shift;
	
	my $stream	= sgrep { $self->apply_rules($_) } $self->SUPER::get_statements( $s, $p, $o, $c );
	return $stream;
}

=item C<< get_pattern ( $bgp [, $context] ) >>

Returns a stream object of all bindings matching the specified graph pattern.

=cut

sub get_pattern {
	my $self	= shift;
	my $bgp		= shift;
	my $context	= shift;
	my %args	= @_;
	
	if (my $o = $args{ orderby }) {
		my @ordering	= @$o;
		while (my ($col, $dir) = splice( @ordering, 0, 2, () )) {
			no warnings 'uninitialized';
			unless ($dir =~ /^(ASC|DESC)$/) {
				throw RDF::Trine::Error -text => 'Direction must be ASC or DESC in get_pattern call';
			}
		}
	}
	
	my @rules	= $self->rules;
	if (@rules) {
		my (@triples)	= ($bgp->isa('RDF::Trine::Statement')) ? $bgp : $bgp->triples;
		unless (@triples) {
			throw RDF::Trine::Error::CompilationError -text => 'Cannot call get_pattern() with empty patter';
		}
		
		my @streams;
		foreach my $triple (@triples) {
			Carp::confess "not a statement object: " . Dumper($triple) unless ($triple->isa('RDF::Trine::Statement'));
			my $stream	= $self->get_statements( $triple->nodes, $context );
			my $binds	= $stream->as_bindings( $triple->nodes );
			push(@streams, $binds);
		}
		if (@streams) {
			while (@streams > 1) {
				my $a	= shift(@streams);
				my $b	= shift(@streams);
				unshift(@streams, RDF::Trine::Iterator->join_streams( $a, $b ));
			}
		} else {
			push(@streams, RDF::Trine::Iterator::Bindings->new([{}], []));
		}
		my $stream	= shift(@streams);
		return $stream;
	} else {
		return $self->SUPER::get_pattern( $bgp, $context, %args );
	}
}

=item C<< apply_rules ( $statement ) >>

=cut

sub apply_rules {
	my $self	= shift;
	my $st		= shift;
	my @rules	= $self->rules;
	foreach my $rule (@rules) {
		return 0 unless ($rule->( $st ));
	}
	return 1;
}

=item C<< rules >>

Returns a list of all rules in the inferencing model.

=cut

sub rules {
	my $self	= shift;
	return @{ $self->{rules} };
}

=item C<< add_rule ( \&rule ) >>

Adds a rule to the inferencing model. The rule should be a CODE reference that,
when passed a statement object, will return true if the statement should be
allowed in the model, false if it should be filtered out.

=cut

sub add_rule {
	my $self	= shift;
	my $rule	= shift;
	throw RDF::Trine::Error -text => "Filter must be a CODE reference" unless (reftype($rule) eq 'CODE');
	push( @{ $self->{rules} }, $rule );
}

1;

__END__

=back

=head1 AUTHOR

 Gregory Todd Williams <gwilliams@cpan.org>

=cut