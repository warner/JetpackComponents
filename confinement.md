
# Confinement in Jetpack Components

## Summary
- Jetpack components ([defined here](components.html)) must be able to
  maintain defensive consistency, so they must be able to retain private and
  uncorrupted internal state despite the behavior of adversarial clients.
- We have multiple options to achieve this confinement. All require some
  involvement by the component (to define what is private and what is
  public). Many involve restrictions applied to client code. Some involve
  wrappers or membranes between components.

## Example

This document will focus on an "XHR Limiter" component, which is constructed
with a URL prefix and a full-powered XHR component. The object it offers to
clients has a very similar interface to the XHR object, but instead of a full
URL, it accepts a suffix: the URL accessed will be the combination of the
fixed prefix and the client-supplied suffix. This prevents the client from
accessing any URL outside the preconfigured prefix, and is not vulnerable to
mistakes in string comparison or regular expression matching.

For simplicty, we will use the `jQuery.get()` method as the full-powered XHR
component. This method has a simpler API than the native `XHRHttpRequest`
object. We define a full-powered XHR object in terms of `jQuery` as follows:

      var FullGet = {
          get: function get(url, callback) {
              return jQuery.get(url, callback);
          }
      }

A full-powered GET-like object would typically be used like this:

      var full_get = require("GET").FullGet
      function done(data, textStatus, request) {
          dump(data);
      }
      full_get.get("http://api.twitter.com/1/statuses/friends_timeline.xml", done);

The LimitedGET implementation might look like this:

      function makeLimitedGET(full_get, prefix) {
        return {
          full_get: full_get,
          prefix: prefix,
          get: function(url_suffix, cb) {
            function remove_request(data, textStatus, request) {
              cb(data, textStatus);
            }
            this.full_get.get(this.prefix + url_suffix, remove_request);
          }
        }
      }

This object would typically be constructed during assembly/linkage time:

      var full_get = require("GET").FullGet
      var limited_get = require("LimitedGET").LimitedGET(full_get, "http://twitter.com/")

And a well-behaved client (which receives only the `limited_get` object)
would normally use it like this:

      limited_get("1/statuses/friends_timeline.xml", done);

## Attacks

The Caja project, which exists to provide this sort of confinement at the
level of web pages, has compiled a list of
[attack vectors](http://code.google.com/p/google-caja/wiki/AttackVectors).
This describes the various things that client might do to violate the
consistency of our noble component. Not all of these attacks are revelant to
the Jetpack environment. In general, Jetpack should have an easier job than
Caja does, because:

- It is not required to retain compatibility with all web pages: Jetpack is a
  new project, and a new environment, and we can teach developers to follow
  slightly different rules.
- It is not required to work on arbitrary browsers: because we have more
  control over the Javascript environment, we can implement restrictions or
  add features to support Jetpack's needs.

A simple attack, against a naïve implementation, would be to extract the
supposedly-private full-powered XHR object from inside the limiter:

      var full_get = limited_get.full_get;
      full_get.open("http://www.bank.com/secret_balance", done);

The Jetpack Components framework must prevent these sorts of attacks in all
circumstances, without requiring deep (human) inspection of all potential
client code. It can use a combination of static and runtime analysis. It must
provide fail-safe behavior: if there is uncertainty, reject the attempt.

## Component Requirements

Each component is required to participate in its own security by defining
which parts are private and which are meant for clients to access. Since
javascript objects are used both for exported behavior (with methods) and as
a generic dictionary/mapping bundle (without methods), it is perfectly valid
for a JS object to be entirely public. However, most client-facing objects
will be providing access to behavior, and therefore need to make the
distinction.

Two likely ways to express this distinction are lexical-scoped variables (the
"closure" approach) and explicitly enumerated properties.

### The Closure Approach

The Caja team, among others, has identified a capability-secure subset of
Javascript in which private state is stored in lexically-scoped variables,
which are generally unavailable to code that is defined outside this scope.
The use of scoping rules to define the private/public boundary (which maps
exactly to inside/outside) removes a lot of the usual confusion. In the
closure approach, method code does not use the `this` keyword to access
private state.

      function makeLimitedGET(full_get, prefix) {
        return {
          get: function(url_suffix, cb) {
            function remove_request(data, textStatus, request) {
              cb(data, textStatus);
            }
            full_get.get(prefix + url_suffix, remove_request);
          }
        }.freeze();
      }

Another example uses private mutable state to maintain an increment-only
counter, which a caller cannot modify or read directly:

      function makeCounter() {
        var count := 0;
        return {
          increment: function() {
                  count += 1;
                }
          read: function() {
                  return "The counter value is " + count;
                }
        }.freeze();
      }

In this approach, any properties defined with literal names (like `get:` or
`increment:`) are publically-visible and immutable. Every behavior-providing
object in the Jetpack component must store its private state in
lexically-accessible variables: if a programmer accidentally stores the state
as a property, that state will be visible to the world. Likewise, all such
objects must be frozen before being allowed to escape the lexical scope: if a
programmer forgets the `freeze()`, their objects will be vulnerable to
corruption by clients (their private state will remain private, however their
methods can be replaced, so other security-affecting assumptions can be
violated).

### Enumerated Properties

The Mozilla platform includes "Chrome Object Wrappers" (see below for
details) which obey a special `__exposedProps__` attribute. As described
below, COWs are not general purpose, but one can imagine a similar mechanism
to give JS objects control over external access to their internal state,
where "external" is defined as "coming from a different domain than my own"
(note: this is unrelated to DNS domains). Each object "lives" in a specific
domain. If the caller's domain and the callee's domain are different, the
wrapper is invoked. If they are the same, the wrapper is not invoked.

TODO: I suspect that round-trips are not handled this way, such that passing
an object through the wrapper and getting it back again results in a wrapped
(or maybe doubly-wrapped) object, rather than receiving the original
unwrapped object. An implementation which works this way would not compare
owners or domains, but would instead just wrap all arguments and return
values.

At the very least, each Jetpack component would represent a different domain,
to allow these components to defend their internal consistency against each
other. However, Jetpack code should have the ability to create these domains
internally, so they can utilize POLA on their internals (and not just their
externals).

The wrapper-style code might look something vaguely like this:

      function makeLimitedGET(full_get, prefix) {
        return {
          __exposedProps__ = {get: "r"};
          full_get: full_get,
          prefix: prefix,
          get: function(url_suffix, cb) {
            function remove_request(data, textStatus, request) {
              cb(data, textStatus);
            }
            this.full_get.get(this.prefix + url_suffix, remove_request);
          }
        }
      }

In the long run, the drawback with wrappers is the performance hit they incur
on each method call. In addition, wrappers frequently cause GC problems,
especially when reference cycles traverse the wrappers. This is usually worse
when the wrappers are not implemented in the same language (e.g. when C++
objects are used to support the wrapping of JS objects), because the
reference counts are hidden.


## Client Requirements

Client code, which is given a reference to a component, must not be able to
read or modify that component's private state. Many of the
[attack vectors](http://code.google.com/p/google-caja/wiki/AttackVectors)
must be blocked by modifying or limiting client code. In some cases this is
performed by static analysis, such as prohibiting `with` or raw `eval` from
appearing in the code. In others, it is performed with runtime checks, such
as the ES5-S prohibition on accessing `arguments.caller`, or restrictions
that prevent object property modification or deletion.

ES5 prohibits most of the attacks that could be used to violate the privacy
of lexically-scoped variables, enabling that technique as an
information-hiding mechanism. If all potential adversary code (i.e. every
piece of code that could ever obtain a reference to our LimitedGET object) is
restricted from using lexical-scope-violating constructs, then
lexical-scoping can be safe. If there is any adversary code that is not
restricted in this way, then lexical-scoping is not safe.

Wrappers have similar issues. The wrapper technology will make some sort of
internal-vs-external distinction, and correct behavior will depend upon some
assumptions about the caller's behavior. If those assumptions can be relied
upon everywhere, then the wrapped code will remain secure. If those
assumptions might not hold everywhere, then the wrapper will not be
sufficient.

## Domains

The collection of components that make up a single add-on (in fact the
collection that makes up the whole browser environment) can be envisioned as
a set of mistrusting domains with objects inside them, like little medieval
fiefdoms filled with people. It may be easier to implement any given
component in a fashion that trusts all of its internal objects (i.e. the
author is willing to have those objects be fully vulnerable to each other),
and only provide defensive consistency against adversarial code from other
components. Or it may be easy enough to let each object be an island, a
domain unto itself.

I imagine each component to include a tag in its manifest (the package.json
file or equivalent), describing what sort of language the component is
written in, with values like "ES5-Strict" or "ADsafe", etc. This tag would
inform the loader what sorts of restrictions to apply to the component's
code. Certain tags would induce wrappers or other barriers to be put in place
around the component, either to protect it against external intrusion (such
as a tag that means "leading underscores on property names mean private"), or
to protect the rest of the world against the insufficiently-constrained
component (such as a tag which says "we allow full ES3 badness here").




## Tools

A variety of tools have been developed in the process of trying to solve this
sort of problem over the years.

- **Caja** http://code.google.com/p/google-caja/ : Caja is a project
  sponsored by Google to provide a secure javascript environment for web
  content. http://google-caja.googlecode.com/files/caja-spec-2008-06-07.pdf
  is a slightly-out-of-date paper describing the goals and approaches taken.
  Caja is one of the object-capabilities community's most complete and
  advanced deliverables for the Javascript/web world.
- **JSHtmlSanitizer**
  http://code.google.com/p/google-caja/wiki/JsHtmlSanitizer : Caja's
  javascript function which takes HTML and removes script and style tags.
  This could be used to guard received data that is expected to be HTML, to
  make sure it contains no active content when displayed in a frame of some
  sort.
- **ES5-Strict** : as pointed out on
  http://code.google.com/p/google-caja/wiki/SubsetRelationships, code written
  in ECMAScript version 5 with `"use strict";` is very nearly
  capability-secure. By requiring Jetpack code to conform to ES5-Strict, we
  should be able to reduce the amount of developer effort and overhead
  necessary to keep Jetpack components properly isolated.
  http://ejohn.org/blog/ecmascript-5-objects-and-properties/ contains
  examples of how ES5 allows control over object mutability.
- **Chrome Object Wrappers**:
  https://wiki.mozilla.org/XPConnect_Chrome_Object_Wrappers defines a
  facility in the Mozilla platform to allow safe access from untrusted code
  to "chrome functionality" (JS objects which have chrome privileges). By
  default, property reads return `undefined`, and property writes throw an
  exception. The wrapped object can expose specific properties by defining a
  `__exposedProps__` property (which, of course, should not be exposed).
  These wrappers are proper Membranes (TODO: confirm): passing an object
  (either through arguments or return values) across a COW will result in a
  new wrapper around the new object. However, these wrappers are not
  general-purpose: they cannot be used to protect non-chrome code in domain A
  from non-chrome code in domain B.

