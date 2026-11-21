@{
    ExcludeRules = @(
        # Status messages use the host stream to keep data pipelines clean.
        'PSAvoidUsingWriteHost'
        # PowerShell 7 reads UTF-8 without a BOM.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
