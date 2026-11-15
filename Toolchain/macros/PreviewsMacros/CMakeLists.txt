# Kiln: no-op #Preview macros, built as a Swift macro plug-in next to ObservationMacros.
add_swift_macro_library(PreviewsMacros
  PreviewsMacros.swift
  SWIFT_DEPENDENCIES
    SwiftSyntax
    SwiftSyntaxMacros
)
