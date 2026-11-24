@{
    ExcludeRules = @(
        # PowerShell 7 reads UTF-8 without a BOM.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
