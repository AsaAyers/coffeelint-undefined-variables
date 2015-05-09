coffeelint-undefined-variables
==============================

[CoffeeLint](http://www.coffeelint.org) rule that checks undefined and unused variables

Installation
------------

```sh
npm install coffeelint-undefined-variables --save-dev
```

Usage
-----

Add the following configuration to `coffeelint.json`:

```json
"undefined_variables": {
    "module": "coffeelint-undefined-variables",
    "environments": {
        "browser": true,
        "angular": true,
        "underscore": true
    }
}
```

Configuration
-------------

Add to field "environments" used javascript-frameworks and libs for ignoring global variables
```json
"undefined_variables": {
    "module": "coffeelint-undefined-variables",
    "environments": {
        "node": true,
        "jquery": true
    }
}
```
