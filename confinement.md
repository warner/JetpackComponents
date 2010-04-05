
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

A full-powered XHR object would typically be used like this:

      function done(aEvt) {
          if (req.readyState == 4) {
              if (req.status == 200)
                  dump(req.responseText);
              else
                  dump("Error");
          }
      }
      var req = new XMLHttpRequest();
      req.open("GET", "http://api.twitter.com/1/statuses/friends_timeline.xml",
               true, username, password);
      req.onreadystatechange = done;
      req.send(null)

The LimitedXHR implementation might look like this:

      function LimitedXHR(xhr, prefix) {
        return {
          xhr: xhr,
          prefix: prefix,
          call: function(url_suffix, options) {
                  return this.xhr.call(this.prefix + url_suffix, options);
                }
        }
      }

This object would typically be constructed during assembly/linkage time:

      var full_xhr = require("XHR").XMLHttpRequest
      var limited_xhr = require("LimitedXHR").LimitedXHR(full_xhr, "http://twitter.com/")

And a well-behaved client (which receives only the `limited_xhr` object)
would normally use it like this:

      var req = new limited_xhr();
      req.open("GET", "1/statuses/friends_timeline.xml", true, username, password);
      req.onreadystatechange = done;
      req.send(null)

Note that, for the purposes of this document, we're restricting our goals to
having a `limited_xhr` object (the product of `new limited_xhr()`) that is
only used by a single client. Mutually distrusting clients will share access
to the parent `limited_xhr` factory, but we do not try to solve the problem
of changing the XHR API to allow sensible cooperation on the per-request
objects it creates.

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

      var req = new limited_xhr();
      full_xhr = req.xhr;
      full_xhr.open("POST", "http://www.bank.com/withdrawal, true);
      req.send(null)

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

      function LimitedXHR(xhr, prefix) {
        return {
          call: function(url_suffix, options) {
                  return xhr.call(prefix + url_suffix, options);
                }
        }.freeze();
      }

Another example uses private mutable state to maintain an increment-only
counter:

      function Counter() {
        var count := 0;
        return {
          increment: function() {
                  count += 1;
                }
          read: function() {
                  return count;
                }
        }.freeze();
      }

In this approach, any properties defined with literal names (like `call:`)
are publically-visible and immutable. Every behavior-providing object in the
Jetpack component must store its private state in lexically-accessible
variables: if a programmer accidentally stores the state as a property, that
state will be visible to the world. Likewise, all such objects must be frozen
before being allowed to escape the lexical scope: if a programmer forgets the
`freeze()`, their objects will be vulnerable to corruption by clients (their
private state will remain private, however their methods can be replaced, so
other security-affecting assumptions can be violated).

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

      function LimitedXHR(xhr, prefix) {
        return {
          __exposedProps__ = {call: "r"},
          call: function(url_suffix, options) {
                  return xhr.call(prefix + url_suffix, options);
                }
        }
      }



## Client Requirements

Client code, which is given a reference to a component, must not be able to
read or modify that component's private state. Many of the attack vectors
listed above must be blocked by modifying or limiting client code. In some
cases this is performed by static analysis, such as XYZ. In others, it is
performed with runtime checks, such as the ES5-S prohibition on accessing
`arguments.caller`, or restrictions that prevent object property modification
or deletion.


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

