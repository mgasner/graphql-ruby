# frozen_string_literal: true

# Here's the "application"
module Jazz
  module Models
    Instrument = Struct.new(:name, :family)
    Ensemble = Struct.new(:name)

    def self.reset
      @data = {
        "Instrument" => [
          Models::Instrument.new("Banjo", :str),
          Models::Instrument.new("Flute", "WOODWIND"),
          Models::Instrument.new("Trumpet", "BRASS"),
          Models::Instrument.new("Piano", "KEYS"),
          Models::Instrument.new("Organ", "KEYS"),
          Models::Instrument.new("Drum Kit", "PERCUSSION"),
        ],
        "Ensemble" => [
          Models::Ensemble.new("Bela Fleck and the Flecktones")
        ],
      }
    end

    def self.data
      @data || reset
    end
  end

  # A custom field class that supports the `upcase:` option
  class BaseField < GraphQL::Object::Field
    def initialize(*args, options, &block)
      @upcase = options.delete(:upcase)
      super(*args, options, &block)
    end

    def to_graphql
      field_defn = super
      if @upcase
        inner_resolve = field_defn.resolve_proc
        field_defn.resolve = ->(obj, args, ctx) {
          inner_resolve.call(obj, args, ctx).upcase
        }
      end
      field_defn
    end
  end

  class BaseObject < GraphQL::Object
    # Use this overridden field class
    Field = BaseField

    class << self
      def config(key, value)
        configs[key] = value
      end

      def configs
        @configs ||= {}
      end

      def to_graphql
        type_defn = super
        configs.each do |k,v|
          type_defn.metadata[k] = v
        end
        type_defn
      end
    end
  end

  class BaseInterface < GraphQL::Interface
    # Use this overridden field class
    Field = BaseField
  end


  # Some arbitrary global ID scheme
  class GloballyIdentifiable < BaseInterface
    description "A fetchable object in the system"
    field :id, "ID", "A unique identifier for this object", null: false
    field :upcasedId, "ID", null: false, upcase: true, method: :id

    implemented do
      def id
        GloballyIdentifiable.to_id(@object)
      end
    end

    def self.to_id(object)
      "#{object.class.name.split("::").last}/#{object.name}"
    end

    def self.find(id)
      class_name, object_name = id.split("/")
      Models.data[class_name].find { |obj| obj.name == object_name }
    end
  end

  # A legacy-style interface used by new-style types
  NamedEntity = GraphQL::InterfaceType.define do
    name "NamedEntity"
    field :name, !types.String
  end


  # Here's a new-style GraphQL type definition
  class Ensemble < BaseObject
    implements GloballyIdentifiable, NamedEntity
    description "A group of musicians playing together"
    config :config, :configged
    field :name, "String", null: false
    field :musicians, "[Jazz::Musician]", null: false
    # Test extra arguments:
    field :upcaseName, String, null: false, upcase: true

    def upcase_name
      @object.name # upcase is applied by the superclass
    end
  end

  class Family < GraphQL::Enum
    description "Groups of musical instruments"
    # support string and symbol
    value "STRING", "Makes a sound by vibrating strings", value: :str
    value :WOODWIND, "Makes a sound by vibrating air in a pipe"
    value :BRASS, "Makes a sound by amplifying the sound of buzzing lips"
    value "PERCUSSION", "Makes a sound by hitting something that vibrates"
    value "KEYS", "Neither here nor there, really"
    value "DIDGERIDOO", "Makes a sound by amplifying the sound of buzzing lips", deprecation_reason: "Merged into BRASS"
  end

  # Lives side-by-side with an old-style definition
  using GraphQL::DeprecatedDSL # for ! and types[]
  InstrumentType = GraphQL::ObjectType.define do
    name "Instrument"
    interfaces [NamedEntity]
    implements GloballyIdentifiable

    field :id, !types.ID, "A unique identifier for this object", resolve: ->(obj, args, ctx) { GloballyIdentifiable.to_id(obj) }
    field :upcasedId, !types.ID, resolve: ->(obj, args, ctx) { GloballyIdentifiable.to_id(obj).upcase }
    if RUBY_ENGINE == "jruby"
      # JRuby doesn't support refinements, so the `using` above won't work
      field :family, Family.to_non_null_type
    else
      field :family, !Family
    end
  end

  class Musician < BaseObject
    implements GloballyIdentifiable
    implements NamedEntity
    description "Someone who plays an instrument"
    field :instrument, InstrumentType, null: false
  end

  LegacyInputType = GraphQL::InputObjectType.define do
    name "LegacyInput"
    argument :intValue, !types.Int
  end

  class InspectableInputType < GraphQL::InputObject
    argument :stringValue, String, null: false
    argument :nestedInput, InspectableInputType, null: true
    argument :legacyInput, LegacyInputType, null: true
    def helper_method
      [
        # Context is available in the InputObject
        @context[:message],
        # A GraphQL::Query::Arguments instance is available
        @arguments[:stringValue],
        # Legacy inputs have underscored method access too
        legacy_input ? legacy_input.int_value : "-",
        # Access by method call is available
        "(#{nested_input ? nested_input.helper_method : "-"})",
      ].join(", ")
    end
  end

  # Another new-style definition, with method overrides
  class Query < BaseObject
    field :ensembles, [Ensemble], null: false
    field :find, GloballyIdentifiable, null: true do
      argument :id, "ID", null: false
    end
    field :instruments, [InstrumentType], null: false do
      argument :family, Family, null: true
    end
    field :inspectInput, [String], null: false do
      argument :input, InspectableInputType, null: false
    end

    def ensembles
      Models.data["Ensemble"]
    end

    def find(id:)
      GloballyIdentifiable.find(id)
    end

    def instruments(family: nil)
      objs = Models.data["Instrument"]
      if family
        objs = objs.select { |i| i.family == family }
      end
      objs
    end

    # This is for testing input object behavior
    def inspect_input(input:)
      [
        input.class.name,
        input.helper_method,
        # Access by method
        input.string_value,
        # Access by key:
        input["stringValue"],
        input[:stringValue],
      ]
    end
  end

  class EnsembleInput < GraphQL::InputObject
    argument :name, String, null: false
  end

  class Mutation < BaseObject
    field :addEnsemble, Ensemble, null: false do
      argument :input, EnsembleInput, null: false
    end

    def add_ensemble(input:)
      # TODO, how should this object be presented here?
      # Maybe an instance of the class above, whose methods may be called?
      ens = Models::Ensemble.new(input.name)
      Models.data["Ensemble"] << ens
      ens
    end
  end

  # New-style Schema definition
  class Schema < GraphQL::Schema
    query(Query)
    mutation(Mutation)

    def self.resolve_type(type, obj, ctx)
      class_name = obj.class.name.split("::").last
      ctx.schema.types[class_name]
    end
  end
end
