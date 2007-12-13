# RDF::Query::Algebra::NamedGraph
# -------------
# $Revision: 121 $
# $Date: 2006-02-06 23:07:43 -0500 (Mon, 06 Feb 2006) $
# -----------------------------------------------------------------------------

=head1 NAME

RDF::Query::Algebra::NamedGraph - Algebra class for NamedGraph patterns

=cut

package RDF::Query::Algebra::NamedGraph;

use strict;
use warnings;
use base qw(RDF::Query::Algebra);
use constant DEBUG	=> 0;

use Data::Dumper;
use RDF::Query::Error;
use List::MoreUtils qw(uniq);
use Carp qw(carp croak confess);
use Scalar::Util qw(blessed reftype);
use RDF::SPARQLResults qw(sgrep smap swatch);

######################################################################

our ($VERSION, $debug, $lang, $languri);
BEGIN {
	$debug		= 0;
	$VERSION	= do { my $REV = (qw$Revision: 121 $)[1]; sprintf("%0.3f", 1 + ($REV/1000)) };
}

######################################################################

=head1 METHODS

=over 4

=cut

=item C<new ( $graph, $pattern )>

Returns a new NamedGraph structure.

=cut

sub new {
	my $class	= shift;
	my $graph	= shift;
	my $pattern	= shift;
	return bless( [ 'GRAPH', $graph, $pattern ], $class );
}

=item C<< graph >>

Returns the graph node of the named graph expression.

=cut

sub graph {
	my $self	= shift;
	if (@_) {
		my $graph	= shift;
		$self->[1]	= $graph;
	}
	return $self->[1];
}

=item C<< pattern >>

Returns the graph pattern of the named graph expression.

=cut

sub pattern {
	my $self	= shift;
	return $self->[2];
}

=item C<< sse >>

Returns the SSE string for this alegbra expression.

=cut

sub sse {
	my $self	= shift;
	
	return sprintf(
		'(namedgraph %s %s)',
		$self->graph->sse,
		$self->pattern->sse
	);
}

=item C<< as_sparql >>

Returns the SPARQL string for this alegbra expression.

=cut

sub as_sparql {
	my $self	= shift;
	my $context	= shift;
	my $indent	= shift || '';
	my $string	= sprintf(
		"GRAPH %s %s",
		$self->graph->as_sparql( $context, $indent ),
		$self->pattern->as_sparql( $context, $indent ),
	);
	return $string;
}

=item C<< type >>

Returns the type of this algebra expression.

=cut

sub type {
	return 'GRAPH';
}

=item C<< referenced_variables >>

Returns a list of the variable names used in this algebra expression.

=cut

sub referenced_variables {
	my $self	= shift;
	my @list	= uniq(
		$self->pattern->referenced_variables,
		(map { $_->name } grep { $_->isa('RDF::Query::Node::Variable') } ($self->graph)),
	);
	return @list;
}

=item C<< definite_variables >>

Returns a list of the variable names that will be bound after evaluating this algebra expression.

=cut

sub definite_variables {
	my $self	= shift;
	return uniq(
		map { $_->name } grep { $_->isa('RDF::Query::Node::Variable') } ($self->graph),
		$self->pattern->definite_variables,
	);
}


=item C<< fixup ( $bridge, $base, \%namespaces ) >>

Returns a new pattern that is ready for execution using the given bridge.
This method replaces generic node objects with bridge-native objects.

=cut

sub fixup {
	my $self	= shift;
	my $class	= ref($self);
	my $bridge	= shift;
	my $base	= shift;
	my $ns		= shift;
	
	my $graph	= ($self->graph->isa('RDF::Query::Node'))
				? $bridge->as_native( $self->graph )
				: $self->graph->fixup( $bridge, $base, $ns );
	
	return $class->new( $graph, map { $_->fixup( $bridge, $base, $ns ) } ($self->pattern) );
}

=item C<< execute ( $query, $bridge, \%bound, $context, %args ) >>

=cut

sub execute {
	my $self		= shift;
	my $query		= shift;
	my $bridge		= shift;
	my $bound		= shift;
	my $outer_ctx	= shift;
	my %args		= @_;
	
	if ($outer_ctx) {
		throw RDF::Query::Error::QueryPatternError ( -text => "Can't use nested named graphs" );
	}

	my $context			= $self->graph;
	my $named_triples	= $self->pattern;
	
	_debug( 'named triples: ' . Dumper($named_triples), 1 ) if (DEBUG);
	
	
	my $nstream;
	foreach my $nmodel_data (values %{ $query->{named_models} }) {	# XXX shouldn't be poking directly into $query
		my ($nbridge, $name)	= @{ $nmodel_data };
		my $_stream	= $named_triples->execute( $query, $nbridge, $bound, $context, %args );
		
		my $stream;
		if (blessed($context) and $context->isa('RDF::Query::Node::Variable')) {
			my $cvar	= $context->name;
			my $sub	= sub {
				my $row	= $_stream->next();
				return unless ($row);
				my %row	= %$row;
				$row{ $cvar }	= $name;
				return \%row;
			};
			$stream	= RDF::SPARQLResults::Bindings->new( $sub, [uniq($_stream->binding_names, $cvar)], bridge => $bridge );
# 			$stream	= smap {
# 				my $row	= $_;
# 				return { %$row, $cvar => $name };
# 			} $stream, 'bindings', [$stream->binding_names, $context->name];
		} else {
			$stream	= $_stream;
		}
		
		if (defined($nstream)) {
			$nstream	= $nstream->concat( $stream );
		} else {
			$nstream	= $stream;
		}
	}
	
	unless ($nstream) {
		$nstream	= RDF::SPARQLResults::Bindings->new( [], [] );
	}
	_debug( 'named stream: ' . $nstream, 1 ) if (DEBUG);
	_debug_closure( $nstream ) if (DEBUG);
	
	_debug( 'got named stream' ) if (DEBUG);
	return $nstream;
}

1;

__END__

=back

=head1 AUTHOR

 Gregory Todd Williams <gwilliams@cpan.org>

=cut
