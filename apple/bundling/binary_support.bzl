# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Binary creation support functions."""

load(
    "@build_bazel_rules_apple//apple/bundling:entitlements.bzl",
    "entitlements",
)
load(
    "@build_bazel_rules_apple//apple/bundling:product_support.bzl",
    "apple_product_type",
    "product_support",
)
load(
    "@build_bazel_rules_apple//common:providers.bzl",
    "providers",
)
load(
    "@build_bazel_rules_apple//apple/bundling:platform_support.bzl",
    "platform_support",
)


def _get_binary_provider(deps, provider_key):
  """Returns the provider from a rule's binary dependency.

  Bundling rules depend on binary rules via the "deps" attribute, which
  canonically supports a label list. This function validates that the
  "deps" attribute has only a single value, as is expected for bundling
  rules, before extracting and returning the provider of the given key.

  Args:
    deps: The list of the target's dependencies.
    provider_key: The key of the provider to return.
  Returns:
    The provider propagated by the single "deps" target of the current rule.
  """
  matching_providers = providers.find_all(deps, provider_key)
  if matching_providers:
    if len(matching_providers) > 1:
      fail("Expected only one binary provider")
    return matching_providers[0]
  return None


def _create_stub_binary(ctx):
  """Creates a binary for a bundle by copying a stub from the SDK.

  Some Apple bundles may not need a binary target depending on their product
  type; for example, watchOS applications and iMessage sticker packs contain
  stub binaries copied from the platform SDK, rather than binaries with user
  code. This function creates an `apple_stub_binary` target (instead of
  `apple_binary`) that ensures that the platform transition is correct (for
  platform selection in downstream dependencies) but that does not cause any
  user code to be linked.

  Args:
    ctx: The bundling rule context.

  Returns:
    The binary stub artifact copied out of the SDK.
  """
  product_type = product_support.product_type(ctx)
  product_type_descriptor = product_support.product_type_descriptor(
      product_type)

  if not product_type_descriptor or not product_type_descriptor.stub:
    fail(('%s failed: create_stub_binary may only be called from a bundling ' +
         'rule of a product type which declares a stub') % ctx.label)

  output_artifact = ctx.new_file("stubs/%s.binary_stub" % (ctx.label.name))

  platform_support.xcode_env_action(
      ctx,
      outputs=[output_artifact],
      executable=ctx.executable._xcrunwrapper,
      arguments=["/bin/cp",
                 product_type_descriptor.stub.xcenv_based_path,
                 output_artifact.path],
      mnemonic="CopyStubExecutable",
      progress_message="Copying stub executable for %s" % (ctx.label)
  )

  return output_artifact


def _create_stub_binary_target(
    name,
    platform_type,
    stub_descriptor,
    **kwargs):
  """Creates a binary target for a bundle by copying a stub from the SDK.

  Some Apple bundles may not need a binary target depending on their product
  type; for example, watchOS applications and iMessage sticker packs contain
  stub binaries copied from the platform SDK, rather than binaries with user
  code. This function creates an `apple_stub_binary` target (instead of
  `apple_binary`) that ensures that the platform transition is correct (for
  platform selection in downstream dependencies) but that does not cause any
  user code to be linked.

  Args:
    name: The name of the bundle target, from which the binary target's name
        will be derived.
    platform_type: The platform type for which the binary should be copied.
    stub_descriptor: The information about the product type's stub executable.
    **kwargs: The arguments that were passed into the top-level macro.

  Returns:
    A modified copy of `**kwargs` that should be passed to the bundling rule.

  Deprecated:
    Stub binary targets are deprecated. Use create_stub_binary in the bundling
    rule context instead.
  """
  # TODO(b/69630422): Migrate all callers off of apple_stub_binary. Use
  # create_stub_binary in the rule context instead.

  bundling_args = dict(kwargs)

  apple_binary_name = "%s.apple_binary" % name
  minimum_os_version = kwargs.get("minimum_os_version")

  # Remove the deps so that we only pass them to the binary, not to the
  # bundling rule.
  deps = bundling_args.pop("deps", [])

  native.apple_stub_binary(
      name = apple_binary_name,
      minimum_os_version = minimum_os_version,
      platform_type = platform_type,
      xcenv_based_path = stub_descriptor.xcenv_based_path,
      deps = deps,
      tags = ["manual"] + kwargs.get("tags", []),
      testonly = kwargs.get("testonly"),
      visibility = kwargs.get("visibility"),
  )

  bundling_args["binary"] = apple_binary_name
  bundling_args["deps"] = [apple_binary_name]

  # For device builds, make sure that the stub binary still gets signed with the
  # appropriate entitlements (and that they have their substitutions applied).
  entitlements_value = kwargs.get("entitlements")
  provisioning_profile = kwargs.get("provisioning_profile")
  entitlements_name = "%s_entitlements" % name
  entitlements(
      name = entitlements_name,
      bundle_id = kwargs.get("bundle_id"),
      entitlements = entitlements_value,
      platform_type = platform_type,
      provisioning_profile = provisioning_profile,
      validation_mode = kwargs.get("entitlements_validation"),
  )
  bundling_args["entitlements"] = ":" + entitlements_name

  return bundling_args


def _entitlement_args_for_stub(
    name,
    platform_type,
    **kwargs):
  """Creates an entitlements target for a bundle needing only an SDK stub.

  Apple bundles not needing a binary target, for example, watchOS applications
  and iMessage sticker packs, only contain stub binaries copied from the
  platform SDK rather than binaries with user code. This function creates
  only an entitlements target to ensure the stub binary gets appropriately
  signed.

  Args:
    name: The name of the bundle target, from which the binary target's name
        will be derived.
    platform_type: The platform type for which the binary should be copied.
    **kwargs: The arguments that were passed into the top-level macro.

  Returns:
    A modified copy of `**kwargs` that should be passed to the bundling rule.
  """
  bundling_args = dict(kwargs)

  entitlements_value = kwargs.get("entitlements")
  provisioning_profile = kwargs.get("provisioning_profile")
  entitlements_name = "%s_entitlements" % name
  entitlements(
      name = entitlements_name,
      bundle_id = kwargs.get("bundle_id"),
      entitlements = entitlements_value,
      platform_type = platform_type,
      provisioning_profile = provisioning_profile,
      validation_mode = kwargs.get("entitlements_validation"),
  )
  bundling_args["entitlements"] = ":" + entitlements_name
  # This is required by the configuration transition on the 'deps' attribute
  # of the bundling rule.
  bundling_args["platform_type"] = platform_type

  return bundling_args


def _create_linked_binary_target(
    name,
    platform_type,
    linkopts,
    binary_type="executable",
    sdk_frameworks=[],
    extension_safe=False,
    bundle_loader=None,
    suppress_entitlements=False,
    **kwargs):
  """Creates a binary target for a bundle by linking user code.

  This function also wraps the entitlements handling logic. It returns a
  modified copy of the given keyword arguments that has `binary` and
  `entitlements` attributes added if necessary and removes other
  binary-specific options (such as `linkopts`).

  Args:
    name: The name of the bundle target, from which the binary target's name
        will be derived.
    platform_type: The platform type for which the binary should be built.
    linkopts: Extra linking options to be passed to the binary target.
    binary_type: The type of binary to create. Can be "executable",
        "loadable_bundle" or "dylib".
    sdk_frameworks: Additional SDK frameworks that should be linked with the
        final binary.
    extension_safe: If true, compiles and links this framework with
        '-application-extension', restricting the binary to use only
        extension-safe APIs. False by default.
    bundle_loader: Label to an apple_binary target that will act as the
        bundle_loader for this apple_binary. Can only be set if binary_type is
        "loadable_bundle".
    suppress_entitlements: True/False, indicates that the entitlements() should
        be suppressed.
    **kwargs: The arguments that were passed into the top-level macro.
  Returns:
    A modified copy of `**kwargs` that should be passed to the bundling rule.
  """
  bundling_args = dict(kwargs)

  minimum_os_version = kwargs.get("minimum_os_version")
  provisioning_profile = kwargs.get("provisioning_profile")

  if suppress_entitlements:
    entitlements_deps = []
  else:
    entitlements_value = bundling_args.pop("entitlements", None)
    entitlements_name = "%s_entitlements" % name
    entitlements(
        name = entitlements_name,
        bundle_id = kwargs.get("bundle_id"),
        entitlements = entitlements_value,
        platform_type = platform_type,
        provisioning_profile = provisioning_profile,
        validation_mode = kwargs.get("entitlements_validation"),
    )
    bundling_args["entitlements"] = ":" + entitlements_name
    entitlements_deps = [":" + entitlements_name]

  # Remove the deps so that we only pass them to the binary, not to the
  # bundling rule.
  deps = bundling_args.pop("deps", [])

  # Link the executable from any library deps provided. Pass the entitlements
  # target as an extra dependency to the binary rule to pick up the extra
  # linkopts (if any) propagated by it.
  apple_binary_name = "%s.apple_binary" % name
  native.apple_binary(
      name = apple_binary_name,
      binary_type = binary_type,
      bundle_loader = bundle_loader,
      dylibs = kwargs.get("frameworks"),
      extension_safe = extension_safe,
      features = kwargs.get("features"),
      linkopts = linkopts + ["-rpath", "@executable_path/../../Frameworks"],
      minimum_os_version = minimum_os_version,
      platform_type = platform_type,
      sdk_frameworks = sdk_frameworks,
      deps = deps,
      # TODO(b/64611007): We use non-propagated deps as a workaround for now to
      # ensure that the linkopts and link_inputs for the entitlements don't get
      # propagated to dependent binaries, like test bundles.
      non_propagated_deps = entitlements_deps,
      tags = ["manual"] + kwargs.get("tags", []),
      testonly = kwargs.get("testonly"),
      visibility = kwargs.get("visibility"),
  )
  bundling_args["binary"] = apple_binary_name
  bundling_args["deps"] = [":" + apple_binary_name]

  return bundling_args


def _create_binary(name, platform_type, suppress_entitlements=False, **kwargs):
  """Creates a binary target for a bundle.

  This function checks the desired product type of the bundle and creates either
  an `apple_binary` or `apple_stub_binary` depending on what the product type
  needs. It must be called from one of the top-level application or extension
  macros, because it invokes a rule to create a target. As such, it cannot be
  called within rule implementation functions.

  Args:
    name: The name of the bundle target, from which the binary target's name
        will be derived.
    platform_type: The platform type for which the binary should be built.
    suppress_entitlements: True/False, indicates that the entitlements() should
        be suppressed.
    **kwargs: The arguments that were passed into the top-level macro.
  Returns:
    A modified copy of `**kwargs` that should be passed to the bundling rule.
  """
  args_copy = dict(kwargs)

  binary_type = args_copy.pop("binary_type", "executable")
  linkopts = args_copy.pop("linkopts", [])
  sdk_frameworks = args_copy.pop("sdk_frameworks", [])
  extension_safe = args_copy.pop("extension_safe", False)
  bundle_loader = args_copy.pop("bundle_loader", None)

  # If a user provides a "binary" attribute of their own, it is ignored and
  # silently overwritten below. Instead of allowing this, we should fail fast
  # to prevent confusion.
  if "binary" in args_copy:
    fail("Do not provide your own binary; one will be linked from your deps.",
         attr="binary")

  # Note the pop/get difference here. If the attribute is present as "private",
  # we want to pop it off so that it does not get passed down to the underlying
  # bundling rule (this is the macro's way of giving us default information in
  # the rule that we don't have access to yet). If the argument is present
  # without the underscore, then we leave it in so that the bundling rule can
  # access the value the user provided in their build target (if any).
  product_type = args_copy.pop("_product_type", None)
  if not product_type:
    product_type = args_copy.get("product_type")

  product_type_descriptor = product_support.product_type_descriptor(
      product_type)
  if product_type_descriptor and product_type_descriptor.stub:
    if suppress_entitlements:
      fail("INTERNAL ERROR: suppress_entitlements unsupported on stubs.")
    return _create_stub_binary_target(
        name, platform_type, product_type_descriptor.stub, **args_copy)
  else:
    return _create_linked_binary_target(
        name, platform_type, linkopts, binary_type, sdk_frameworks,
        extension_safe, bundle_loader, suppress_entitlements=suppress_entitlements,
        **args_copy)


# Define the loadable module that lists the exported symbols in this file.
binary_support = struct(
    create_binary=_create_binary,
    create_stub_binary=_create_stub_binary,
    entitlement_args_for_stub=_entitlement_args_for_stub,
    get_binary_provider=_get_binary_provider,
)
