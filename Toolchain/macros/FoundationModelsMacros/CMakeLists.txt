# Kiln: @Generable and @Guide for FoundationModels (Apple's plug-in is closed source and only ships
# with Xcode), built as a Swift macro plug-in next to ObservationMacros.
add_swift_macro_library(FoundationModelsMacros
  FoundationModelsMacros.swift
  SWIFT_DEPENDENCIES
    SwiftSyntax
    SwiftSyntaxBuilder
    SwiftSyntaxMacros
)
