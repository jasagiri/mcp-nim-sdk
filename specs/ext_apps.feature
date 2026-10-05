Feature: MCP Apps (io.modelcontextprotocol/ui), an official extension
  As the author of an MCP server or of a host application
  I want to serve and embed the UIs the MCP Apps specification defines
  So that a tool can come with an interactive view, safely

  Based on the stable specification 2026-01-26, ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f.

  @spec:MCP-EXT-APPS-1
  Scenario: UI resource URIs use the reserved ui:// scheme
    Given a URI for a UI resource
    When it is checked
    Then only ui:// URIs that name something and hold no whitespace or control characters pass

  @spec:MCP-EXT-APPS-2
  Scenario: The metadata of a UI resource has the specification's wire form
    Given a resource's _meta.ui with csp, permissions, domain and prefersBorder
    When it is parsed and written
    Then it round-trips, wrong types are refused and unknown permissions are not granted

  @spec:MCP-EXT-APPS-3
  Scenario: Origins that reach a CSP header are plain origins
    Given a csp declaration
    When its origins are checked
    Then anything that could end or extend a directive is refused

  @spec:MCP-EXT-APPS-4
  Scenario: A tool points at its UI with _meta.ui.resourceUri and a visibility
    Given a tool's _meta
    When its UI reference is read
    Then visibility defaults to model and app, the deprecated flat key is a fallback, and csp or permissions on a tool are refused

  @spec:MCP-EXT-APPS-5
  Scenario: The host builds the CSP and the allow attribute from the declaration
    Given a UI resource's declared csp and permissions
    When the host builds its policies
    Then undeclared origins are never allowed and the restrictive default applies without a csp

  @spec:MCP-EXT-APPS-6
  Scenario: A host declares MCP Apps with the mime types it supports
    Given a client
    When it declares io.modelcontextprotocol/ui
    Then the declaration carries mimeTypes in every version, a malformed one is refused, and it is fixed at connect

  @spec:MCP-EXT-APPS-7
  Scenario: MCP Apps is off unless registered
    Given a program that did not opt in
    When it registers a server or connects a client
    Then nothing is declared, and the server never declares an extension

  @spec:MCP-EXT-APPS-8
  Scenario: A server serves UI resources with their metadata on the content item
    Given a registry of UI resources
    When a client lists and reads them
    Then the entries and contents have the specification's shape and bad registrations are refused

  @spec:MCP-EXT-APPS-9
  Scenario: A tool built for a UI resource names a resource that exists
    Given a registry
    When a tool is built for a URI
    Then _meta.ui carries resourceUri and visibility and an unregistered URI raises

  @spec:MCP-EXT-APPS-10
  Scenario: A server shows UI references only to a host that declared MCP Apps
    Given a server and clients that did and did not declare the extension with the HTML mime type
    When they list tools
    Then only the declaring host sees _meta.ui and the rest see plain tools

  @spec:MCP-EXT-APPS-11
  Scenario: A host reads the UI references and visibility of the tools
    Given a server's tools/list answer
    When the host lists tools with listAppTools
    Then _meta is kept, malformed references are reported, tools without model are not shown to the agent and tools without app are not callable by a View

  @spec:MCP-EXT-APPS-12
  Scenario: A host checks a UI resource before anything renders it
    Given a server's resources/read answer for a ui:// URI
    When the host fetches it
    Then the mime type, scheme, text or blob, base64, size limit and metadata are checked, and nothing is sent for a bad URI or an undeclared host

  @spec:MCP-EXT-APPS-13
  Scenario: The host follows the ui/initialize handshake and its ordering rules
    Given a View
    When it initializes and the host sends notifications
    Then the host answers ui/initialize, sends nothing before initialized, and keeps tool-input before tool-result

  @spec:MCP-EXT-APPS-14
  Scenario: The host builds its messages to the View
    Given tool input, results, cancellation, teardown and context changes
    When the host builds them
    Then they have the specification's methods and params and invalid input is refused

  @spec:MCP-EXT-APPS-15
  Scenario: The host validates what a View asks for
    Given a View's requests and notifications
    When the host parses them
    Then malformed ones are refused, links are limited to http and https, and display modes follow the declared support

  @spec:MCP-EXT-APPS-16
  Scenario: Sandbox proxy messages and routing follow the specification
    Given a web host with a sandbox proxy
    When messages are built and routed
    Then sandbox-reserved messages are not forwarded and ui/ methods do not go to the server

  @spec:MCP-EXT-APPS-17
  Scenario: MCP Apps is negotiated in the initialize handshake of versions before 2026-07-28
    Given a host and a server that agreed on a version before 2026-07-28
    When the host declares io.modelcontextprotocol/ui in the capabilities of initialize
    Then the server lists UI references to it and plain tools to a host that did not declare
