#pragma once
 
#include "CoreMinimal.h"
#include "UObject/ObjectMacros.h"
#include "MaterialExpressionIO.h"
#include "Materials/MaterialExpressionCustomOutput.h"
#include "MaterialExpressionGlintyWaterCustomOutput.generated.h"
 
UCLASS()
class UMaterialExpressionGlintyWaterOutput : public UMaterialExpressionCustomOutput
{
    GENERATED_UCLASS_BODY()
 
    UPROPERTY(meta = (RequiredInput = "true"))
    FExpressionInput TexCoordInput;

    UPROPERTY(meta = (RequiredInput = "true"))
    FExpressionInput Normal1Input;

    UPROPERTY(meta = (RequiredInput = "true"))
    FExpressionInput Normal2Input;

    UPROPERTY(meta = (RequiredInput = "true"))
    FExpressionInput SigmasRho;

    UPROPERTY(meta = (RequiredInput = "true"))
    FExpressionInput LightVector;

    UPROPERTY(meta = (RequiredInput = "true"))
    FExpressionInput Density;
 
#if WITH_EDITOR
    virtual int32 Compile(class FMaterialCompiler* Compiler, int32 OutputIndex) override;
    virtual void GetCaption(TArray<FString>& OutCaptions) const override;
    virtual uint32 GetInputType(int32 InputIndex) override;
    virtual FExpressionInput* GetInput(int32 InputIndex) override;
#endif
    virtual int32 GetNumOutputs() const override { return 6; }
    virtual FString GetFunctionName() const override { return TEXT("GetGlintyWaterParams"); }
    virtual FString GetDisplayName() const override { return TEXT("Glinty Water Params"); }
};