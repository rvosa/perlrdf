package RDF::Query::Model::RDFStoreDBI;

use strict;
use warnings;
use base qw(RDF::Query::Model);

use Carp qw(carp croak confess);

use RDF::Parser;
use RDF::Query::Error (':try');
use File::Spec;
use RDF::Store::DBI;
use Data::Dumper;
use Scalar::Util qw(blessed reftype);
use LWP::Simple qw(get);
use Encode;

use RDF::SPARQLResults;

######################################################################

our ($VERSION, $debug);
BEGIN {
	$debug		= 0;
	$VERSION	= do { my $REV = (qw$Revision: 174 $)[1]; sprintf("%0.3f", 1 + ($REV/1000)) };
}

######################################################################

=head1 METHODS

=over 4

=item C<new ( $model )>

Returns a new bridge object for the specified C<$model>.

=cut

sub new {
	my $class	= shift;
	my $model	= shift;
	my %args	= @_;
	
	if (not defined $model) {
		$model	= RDF::Store::DBI->temporary_store();
	}

	throw RDF::Query::Error::MethodInvocationError ( -text => 'Not a RDF::Store::DBI passed to bridge constructor' ) unless (blessed($model) and $model->isa('RDF::Store::DBI'));
	
	my $self	= bless( {
					model	=> $model,
					parsed	=> $args{parsed},
				}, $class );
}

=item C<< meta () >>

Returns a hash reference with information (class names) about the underlying
backend. The keys of this hash are 'class', 'model', 'statement', 'node',
'resource', 'literal', and 'blank'.

'class' is the name of the bridge class. All other keys refer to backend classes.
For example, 'node' is the backend superclass of all node objects (literals,
resources and blanks).

=cut

sub meta {
	return {
		class		=> __PACKAGE__,
		model		=> 'RDF::Store::DBI',
		statement	=> 'RDF::Query::Algebra::Triple',
		node		=> 'RDF::Query::Node',
		resource	=> 'RDF::Query::Node::Resource',
		literal		=> 'RDF::Query::Node::Literal',
		blank		=> 'RDF::Query::Node::Blank',
	};
}

=item C<model ()>

Returns the underlying model object.

=cut

sub model {
	my $self	= shift;
	return $self->{'model'};
}

=item C<new_resource ( $uri )>

Returns a new resource object.

=cut

sub new_resource {
	my $self	= shift;
	my $uri		= shift;
	if ($self->is_resource( $uri )) {
		return $uri;
	} else {
		my $node	= RDF::Query::Node::Resource->new( $uri );
		return $node;
	}
}

=item C<new_literal ( $string, $language, $datatype )>

Returns a new literal object.

=cut

sub new_literal {
	my $self	= shift;
	my $value	= shift;
	my $lang	= shift;
	my $type	= shift;
	return RDF::Query::Node::Literal->new( $value, $lang, $type );
}

=item C<new_blank ( $identifier )>

Returns a new blank node object.

=cut

sub new_blank {
	my $self	= shift;
	my $name	= shift;
	return RDF::Query::Node::Blank->new( $name );
}

=item C<new_statement ( $s, $p, $o )>

Returns a new statement object.

=cut

sub new_statement {
	my $self	= shift;
	my ($s, $p, $o)	= @_;
	return RDF::Query::Algebra::Triple->new( $s, $p, $o );
}

=item C<new_variable ( $name )>

Returns a new variable object.

=cut

sub new_variable {
	my $self	= shift;
	unless (@_) {
		my $name	= '__rdfstoredbi_variable_' . $self->{_blank_id}++;
		push(@_, $name);
	}
	my $name	= shift;
	return RDF::Query::Node::Variable->new( $name );
}

=item C<is_node ( $node )>

=item C<isa_node ( $node )>

Returns true if C<$node> is a node object for the current model.

=cut

sub isa_node {
	my $self	= shift;
	my $node	= shift;
	return (blessed($node) and $node->isa('RDF::Query::Node'));
}

=item C<is_resource ( $node )>

=item C<isa_resource ( $node )>

Returns true if C<$node> is a resource object for the current model.

=cut

sub isa_resource {
	my $self	= shift;
	my $node	= shift;
	return (blessed($node) and $node->isa('RDF::Query::Node::Resource'));
}

=item C<is_literal ( $node )>

=item C<isa_literal ( $node )>

Returns true if C<$node> is a literal object for the current model.

=cut

sub isa_literal {
	my $self	= shift;
	my $node	= shift;
	return (blessed($node) and $node->isa('RDF::Query::Node::Literal'));
}

=item C<is_blank ( $node )>

=item C<isa_blank ( $node )>

Returns true if C<$node> is a blank node object for the current model.

=cut

sub isa_blank {
	my $self	= shift;
	my $node	= shift;
	return (blessed($node) and $node->isa('RDF::Query::Node::Blank'));
}
no warnings 'once';
*RDF::Query::Model::RDFStoreDBI::is_node		= \&isa_node;
*RDF::Query::Model::RDFStoreDBI::is_resource	= \&isa_resource;
*RDF::Query::Model::RDFStoreDBI::is_literal		= \&isa_literal;
*RDF::Query::Model::RDFStoreDBI::is_blank		= \&isa_blank;

=item C<< equals ( $node_a, $node_b ) >>

Returns true if C<$node_a> and C<$node_b> are equal

=cut

sub equals {
	my $self	= shift;
	my $nodea	= shift;
	my $nodeb	= shift;
	return $nodea->equal( $nodeb );
}


=item C<as_string ( $node )>

Returns a string version of the node object.

=cut

sub as_string {
	my $self	= shift;
	my $node	= shift;
	return unless blessed($node);
	if ($self->isa_resource( $node )) {
		my $uri	= $node->uri_value;
		return qq<[$uri]>;
	} elsif ($self->isa_literal( $node )) {
		my $value	= $self->literal_value( $node );
		my $lang	= $self->literal_value_language( $node );
		my $dt		= $self->literal_datatype( $node );
		if ($lang) {
			return qq["$value"\@${lang}];
		} elsif ($dt) {
			return qq["$value"^^<$dt>];
		} else {
			return qq["$value"];
		}
	} elsif ($self->isa_blank( $node )) {
		my $id	= $self->blank_identifier( $node );
		return qq[($id)];
	} elsif (blessed($node) and $node->isa('RDF::Query::Algebra::Triple')) {
		return $node->as_sparql;
	} else {
		return;
	}
}

=item C<literal_value ( $node )>

Returns the string value of the literal object.

=cut

sub literal_value {
	my $self	= shift;
	my $node	= shift;
	return unless ($self->is_literal( $node ));
	return $node->literal_value;
}

=item C<literal_datatype ( $node )>

Returns the datatype of the literal object.

=cut

sub literal_datatype {
	my $self	= shift;
	my $node	= shift;
	return unless ($self->is_literal( $node ));
	my $type	= $node->literal_datatype;
	return $type;
}

=item C<literal_value_language ( $node )>

Returns the language of the literal object.

=cut

sub literal_value_language {
	my $self	= shift;
	my $node	= shift;
	return unless ($self->is_literal( $node ));
	my $lang	= $node->literal_value_language;
	return $lang;
}

=item C<uri_value ( $node )>

Returns the URI string of the resource object.

=cut

sub uri_value {
	my $self	= shift;
	my $node	= shift;
	return unless ($self->is_resource( $node ));
	return $node->uri_value;
}

=item C<blank_identifier ( $node )>

Returns the identifier for the blank node object.

=cut

sub blank_identifier {
	my $self	= shift;
	my $node	= shift;
	return unless ($self->is_blank( $node ));
	return $node->blank_identifier;
}

=item C<add_uri ( $uri, $named, $format )>

Addsd the contents of the specified C<$uri> to the model.
If C<$named> is true, the data is added to the model using C<$uri> as the
named context.

=cut

sub add_uri {
	my $self		= shift;
	my $uri			= shift;
	my $named		= shift;
	my $format		= shift || 'guess';
	
	my $content		= get( $uri );
	$self->add_string( $content, $uri, $named, $format );
}

=item C<add_string ( $data, $base_uri, $named, $format )>

Added the contents of C<$data> to the model. If C<$named> is true,
the data is added to the model using C<$base_uri> as the named context.

=cut

sub add_string {
	my $self	= shift;
	my $data	= shift;
	my $base	= shift;
	my $named	= shift;
	my $format	= shift || 'guess';
	
	if (not $named) {
		$self->ignore_contexts();
	}
	
	$self->set_context( $base );
	my $parser	= RDF::Parser->new('turtle');
	try {
		$parser->parse_into_model( $base, $data, $self );
	} catch RDF::Parser::Error with {
		require RDF::Redland;
		my $uri		= RDF::Redland::URI->new( $base );
		my $parser	= RDF::Redland::Parser->new($format);
		my $stream	= $parser->parse_string_as_stream($data, $uri);
		while ($stream and !$stream->end) {
			my $statement	= $stream->current;
			my $stmt		= RDF::Query::Algebra::Triple->from_redland( $statement );
			$self->add_statement( $stmt );
			$stream->next;
		}
	}
}

=item C<statement_method_map ()>

Returns an ordered list of method names that when called against a statement
object will return the subject, predicate, and object objects, respectively.

=cut

sub statement_method_map {
	return qw(subject predicate object);
}

=item C<< subject ( $statement ) >>

Returns the subject node of the specified C<$statement>.

=cut

sub subject {
	my $self	= shift;
	my $stmt	= shift;
	return $stmt->subject;
}

=item C<< predicate ( $statement ) >>

Returns the predicate node of the specified C<$statement>.

=cut

sub predicate {
	my $self	= shift;
	my $stmt	= shift;
	return $stmt->predicate;
}

=item C<< object ( $statement ) >>

Returns the object node of the specified C<$statement>.

=cut

sub object {
	my $self	= shift;
	my $stmt	= shift;
	return $stmt->object;
}

=item C<get_statements ($subject, $predicate, $object)>

Returns a stream object of all statements matching the specified subject,
predicate and objects. Any of the arguments may be undef to match any value.

=cut

sub get_statements {
	my $self	= shift;
	my @triple	= splice(@_, 0, 3);
	my $context	= shift;
	if ($context and $context->isa('RDF::Query::Node::Resource')) {
		unless ($self->equals( $context, $self->get_context)) {
			return RDF::SPARQLResults::Graph->new( [], bridge => $self );
		}
	}
	
	my $model	= $self->{'model'};
	my $stream	= $model->get_statements( map { $self->is_node($_) ? $_ : $self->new_variable() } @triple );
	return $stream;
}

=item C<< add_statement ( $statement ) >>

Adds the specified C<$statement> to the underlying model.

=cut

sub add_statement {
	my $self	= shift;
	my $stmt	= shift;
	my $model	= $self->model;
	$model->add_statement( $stmt );
}

=item C<< remove_statement ( $statement ) >>

Removes the specified C<$statement> from the underlying model.

=cut

sub remove_statement {
	my $self	= shift;
	my $stmt	= shift;
	my $model	= $self->model;
	$model->remove_statement( $stmt );
}

=item C<get_context ($stream)>

Returns the context node of the last statement retrieved from the specified
C<$stream>. The stream object, in turn, calls the closure (that was passed to
the stream constructor in C<get_statements>) with the argument 'context'.

=cut

sub get_context {
	my $self	= shift;
	if (exists($self->{context})) {
		return $self->new_resource( $self->{context} );
	} else {
		return;
	}
}

=item C<< set_context ( $url ) >>

Sets the context of triples in this model.

=cut

sub set_context {
	my $self	= shift;
	my $name	= shift;
	if (exists($self->{context}) and not($self->{ignore_contexts})) {
		Carp::confess "RDF::Store::DBI models can only represent a single context" unless ($self->{context} eq $name);
	}
	$self->{context}	= $name;
}

=begin private

=item C<< ignore_contexts >>

=end private

=cut

sub ignore_contexts {
	my $self	= shift;
	$self->{ignore_contexts}	= 1;
}

=item C<supports ($feature)>

Returns true if the underlying model supports the named C<$feature>.
Possible features include:

	* named_graph
	* node_counts
	* temp_model
	* xml

=cut

sub supports {
	my $self	= shift;
	my $feature	= shift;
	return 1 if ($feature eq 'xml');
	return 0;
}

=item C<< unify_bgp ( $bgp, \%bound, $context, %args ) >>

Called with a RDF::Query::Algebra::BasicGraphPattern for execution all-at-once
instead of making individual execute() calls on all the constituent
RDF::Query::Algebra::Triple patterns and joining them.

C<< $context >> is currently ignored as the calling code in
RDF::Query::Algebra::BasicGraphPattern::execute is currently ensuring that
we do the right thing w.r.t. named graphs. Should probably change in the future
as named graph support is moved into the model bridge code.

=cut

sub unify_bgp {
	my $self	= shift;
	my $bgp		= shift;
	my $bound	= shift;
	my $context	= shift;
	my %args	= @_;
	
	if ($context and $context->isa('RDF::Query::Node::Resource')) {
		unless ($self->equals( $context, $self->get_context)) {
			return RDF::SPARQLResults::Bindings->new( [], [], bridge => $self );
		}
	}
	
	my $pattern	= $bgp->clone;
	my $model	= $self->model;
	foreach my $triple ($pattern->triples) {
		foreach my $method (qw(subject predicate object)) {
			my $node	= $triple->$method();
			if ($node->isa('RDF::Query::Node::Blank')) {
				my $var	= RDF::Query::Node::Variable->new( '__' . $node->blank_identifier );
				$triple->$method( $var );
			}
		}
	}
	
	# BINDING has to happen after the blank->var substitution above, because
	# we might have a bound bnode.
	$pattern	= $pattern->bind_variables( $bound );
	
	my @args;
	if (my $o = $args{ orderby }) {
		push( @args, orderby => [ map { $_->[1]->name => $_->[0] } grep { blessed($_->[1]) and $_->[1]->isa('RDF::Query::Node::Variable') } @$o ] );
	}
	
	return $model->get_pattern( $pattern, undef, @args );
}

1;

__END__

=back

=cut
